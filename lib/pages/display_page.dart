import 'dart:async';
//import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:qr_flutter/qr_flutter.dart';

import '../state/site_prefs.dart';

class DisplayPage extends StatefulWidget {
  const DisplayPage({super.key});

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage> {
  final supabase = Supabase.instance.client;

  // ✅ Liste affichée (peut être filtrée)
  List<Map<String, dynamic>> vehiclesToProcess = [];

  // ✅ Liste brute reçue (non filtrée) -> on ne touche pas à ta logique serveur
  List<Map<String, dynamic>> _allVehiclesToProcess = [];

  List<Map<String, dynamic>> lastValidated = [];

  int remainingDamage = 0;
  int remainingCarcheck = 0;
  int remainingPhoto = 0;
  int remainingEquipment = 0;
  int remainingAviloo = 0;
  int validated24h = 0;

  bool loading = true;
  RealtimeChannel? _channel;

  static const Duration kMaxDelay = Duration(hours: 48);

  // ✅ Filtre local dates disponibles
  List<DateTime> availableEntryDates = [];
  DateTime? selectedEntryDate;

  @override
  void initState() {
    super.initState();
    _loadAll();

    _channel = supabase.channel('kpi-realtime')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'display_refresh',
        callback: (payload) => _loadAll(),
      )
      ..subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) {
      supabase.removeChannel(_channel!);
    }
    super.dispose();
  }

  // ✅ Nettoie la plaque pour le QR : uniquement lettres et chiffres
  String _sanitizePlateForQr(String plate) {
    return plate.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  // ✅ Popup QR agrandi
  void _showQrPopup({
    required String plate,
    required String qrPlate,
  }) {
    if (qrPlate.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "QR Code véhicule",
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  plate.isEmpty ? "—" : plate,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: QrImageView(
                    data: qrPlate,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  qrPlate,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      "Fermer",
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ✅ convertit une date ISO en "jour" (sans heure)
  DateTime? _toDay(dynamic iso) {
    if (iso == null) return null;
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return null;
    return DateTime(dt.year, dt.month, dt.day);
  }

  // ✅ applique le filtre local sur une liste donnée
  List<Map<String, dynamic>> _filteredListFrom(List<Map<String, dynamic>> all) {
    if (selectedEntryDate == null) return List<Map<String, dynamic>>.from(all);

    return all.where((v) {
      final d = _toDay(v['urgency_time']); // ✅ date d'entrée
      return d != null &&
          d.year == selectedEntryDate!.year &&
          d.month == selectedEntryDate!.month &&
          d.day == selectedEntryDate!.day;
    }).toList();
  }

  // ✅ applique le filtre local sur la liste brute déjà stockée
  void _applyLocalDateFilterFromState() {
    setState(() {
      vehiclesToProcess = _filteredListFrom(_allVehiclesToProcess);
    });
  }

  String _todayKpiDateUtc() {
    final now = DateTime.now().toUtc();
    final yyyy = now.year.toString().padLeft(4, '0');
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return "$yyyy-$mm-$dd";
  }

  Future<void> _loadAll() async {
    try {
      setState(() => loading = true);

      final selectedSite = await SitePrefs.getSite();
      final kpiDate = _todayKpiDateUtc();

      // 1) Plaques du site sélectionné + forecast ventes depuis kpi_vehicles
      final siteRows = await supabase
          .from('kpi_vehicles')
          .select('plate, forecast_sales')
          .eq('kpi_date', kpiDate)
          .ilike('site', '%$selectedSite%');

      final siteMap = <String, String>{};

      for (final row in (siteRows as List)) {
        final plate = (row['plate'] ?? '').toString().trim();
        final forecast = (row['forecast_sales'] ?? '').toString().trim();

        if (plate.isNotEmpty) {
          siteMap[plate] = forecast;
        }
      }

      final sitePlates = siteMap.keys.toSet();

      // 2) Statut validations (logique OK) depuis vehicle_status_today
      final leftAll = await supabase
          .from('vehicle_status_today')
          .select()
          .order('fully_validated', ascending: true)
          .order('urgency_time', ascending: true);

      // 3) Filtre par site + injection du forecast_sales si absent dans vehicle_status_today
      final left = (leftAll as List)
          .map((e) => Map<String, dynamic>.from(e))
          .where((v) {
        if (sitePlates.isEmpty) return true;
        return sitePlates.contains((v['plate'] ?? '').toString().trim());
      })
          .map((v) {
        final plate = (v['plate'] ?? '').toString().trim();
        final existingForecast = (v['forecast_sales'] ?? '').toString().trim();

        if (existingForecast.isEmpty && siteMap.containsKey(plate)) {
          v['forecast_sales'] = siteMap[plate];
        }

        return v;
      })
          .toList();

      final right = await supabase
          .from('last_fully_validated_30')
          .select()
          .order('last_validation_at', ascending: false);

      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(hours: 24));

      int dmg = 0, car = 0, pho = 0, eqp = 0, avi = 0, v24 = 0;

      // ✅ ta logique KPI reste basée sur "left" (non filtré)
      for (final row in left) {
        final requiredDamage = row['required_damage'] == true;
        final requiredCarcheck = row['required_carcheck'] == true;
        final requiredPhoto = row['required_photo'] == true;
        final requiredEquipment = row['required_equipment'] == true;
        final requiredAviloo = row['required_aviloo'] == true;

        final doneEquipment = row['done_equipment'] == true;
        final doneAviloo = row['done_aviloo'] == true;
        final doneDamage = row['done_damage'] == true;
        final doneCarcheck = row['done_carcheck'] == true;
        final donePhoto = row['done_photo'] == true;

        if (requiredDamage && !doneDamage) dmg++;
        if (requiredCarcheck && !doneCarcheck) car++;
        if (requiredPhoto && !donePhoto) pho++;
        if (requiredEquipment && !doneEquipment) eqp++;
        if (requiredAviloo && !doneAviloo) avi++;

        if (row['fully_validated'] == true && row['last_validation_at'] != null) {
          final dt = DateTime.tryParse(row['last_validation_at'].toString());
          if (dt != null && dt.isAfter(cutoff)) v24++;
        }
      }

      // ✅ on stocke la liste brute reçue (non filtrée)
      final leftList = List<Map<String, dynamic>>.from(left);

      // ✅ dates disponibles (distinctes + triées)
      final datesSet = <DateTime>{};
      for (final v in leftList) {
        final d = _toDay(v['urgency_time']);
        if (d != null) datesSet.add(d);
      }
      final dates = datesSet.toList()..sort((a, b) => b.compareTo(a)); // plus récent en haut

      // ✅ si la date sélectionnée n’existe plus, reset
      final stillValid = selectedEntryDate == null
          ? true
          : dates.any((d) =>
      d.year == selectedEntryDate!.year &&
          d.month == selectedEntryDate!.month &&
          d.day == selectedEntryDate!.day);

      if (!stillValid) {
        selectedEntryDate = null;
      }

      // ✅ liste affichée = liste brute filtrée localement
      final displayList = _filteredListFrom(leftList);

      setState(() {
        _allVehiclesToProcess = leftList;
        vehiclesToProcess = displayList;

        availableEntryDates = dates;
        lastValidated = List<Map<String, dynamic>>.from(right);

        remainingDamage = dmg;
        remainingCarcheck = car;
        remainingPhoto = pho;
        remainingEquipment = eqp;
        remainingAviloo = avi;
        validated24h = v24;

        loading = false;
      });
    } catch (e) {
      setState(() => loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur affichage : $e")),
      );
    }
  }

  String _taskState({required bool requiredTask, required bool doneTask}) {
    if (!requiredTask) return "not_required";
    return doneTask ? "done" : "missing";
  }

  String _formatTime(dynamic iso) {
    if (iso == null) return "--:--";
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return "--:--";
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return "$hh:$mm";
  }

  String _formatDate(dynamic iso) {
    if (iso == null) return "--/--/----";
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return "--/--/----";
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();
    return "$dd/$mm/$yyyy";
  }

  _DeadlineUI _deadline(dynamic entryIso) {
    final now = DateTime.now();
    final entry = entryIso == null ? null : DateTime.tryParse(entryIso.toString());
    if (entry == null) {
      return const _DeadlineUI(color: Color(0xFF94A3B8), label: "—", sub: "date manquante");
    }

    final deadline = entry.add(kMaxDelay);
    final remaining = deadline.difference(now);

    if (remaining.isNegative) {
      final lateH = remaining.abs().inHours;
      return _DeadlineUI(
        color: const Color(0xFFEF4444),
        label: "RETARD",
        sub: "~${lateH}h",
      );
    }

    final hours = remaining.inHours;
    if (hours <= 24) {
      return _DeadlineUI(
        color: const Color(0xFFF59E0B),
        label: "URGENT",
        sub: "~${hours}h",
      );
    }

    return _DeadlineUI(
      color: const Color(0xFF22C55E),
      label: "OK",
      sub: "~${hours}h",
    );
  }

  @override
  Widget build(BuildContext context) {
    // ===== Thème clair pro =====
    const bg = Color(0xFFF6F7FB);
    const card = Colors.white;
    const card2 = Color(0xFFF2F4F8);
    const border = Color(0xFFE5E7EB);
    const textPrimary = Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);
    const accent = Color(0xFF2563EB);

    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    // ✅ “Compact” Android sans réduire la largeur (contrairement à Transform.scale)
    // Windows = 1.0 (inchangé)
    final double ui = isAndroid ? 0.90 : 1.0;

    double s(double v) => v * ui;

    final mq = MediaQuery.of(context);
    final wrapped = MediaQuery(
      // ✅ évite les boitiers Android qui appliquent un zoom texte énorme
      data: isAndroid ? mq.copyWith(textScaler: const TextScaler.linear(1.0)) : mq,
      child: Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                children: [
                  // ===== TOP BAR (compact) =====
                  Container(
                    padding: EdgeInsets.fromLTRB(s(18), s(14), s(18), s(12)),
                    decoration: const BoxDecoration(
                      color: card,
                      border: Border(bottom: BorderSide(color: border, width: 1)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: s(10),
                          height: s(10),
                          decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
                        ),
                        SizedBox(width: s(10)),
                        Text(
                          "KPI — Display",
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: s(16),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(width: s(12)),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: s(10), vertical: s(6)),
                          decoration: BoxDecoration(
                            color: card2,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: border),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: s(8),
                                height: s(8),
                                decoration: BoxDecoration(
                                  color: loading ? const Color(0xFFF59E0B) : const Color(0xFF22C55E),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              SizedBox(width: s(8)),
                              Text(
                                loading ? "Sync…" : "À jour",
                                style: TextStyle(
                                  color: textMuted,
                                  fontWeight: FontWeight.w800,
                                  fontSize: s(12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),

                        // ✅ Filtre date (local) juste à côté d'Actualiser
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: s(12), vertical: s(2)),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(s(12)),
                            border: Border.all(color: border),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<DateTime?>(
                              value: selectedEntryDate,
                              isDense: true,
                              iconEnabledColor: textPrimary,
                              iconDisabledColor: textMuted,
                              style: TextStyle(
                                color: textPrimary,
                                fontWeight: FontWeight.w900,
                                fontSize: s(12),
                              ),
                              dropdownColor: Colors.white,
                              borderRadius: BorderRadius.circular(s(12)),
                              items: [
                                const DropdownMenuItem<DateTime?>(
                                  value: null,
                                  child: Text("Toutes les dates"),
                                ),
                                ...availableEntryDates.map((d) {
                                  final dd = d.day.toString().padLeft(2, '0');
                                  final mm = d.month.toString().padLeft(2, '0');
                                  final yyyy = d.year.toString();
                                  return DropdownMenuItem<DateTime?>(
                                    value: d,
                                    child: Text("$dd/$mm/$yyyy"),
                                  );
                                }).toList(),
                              ],
                              onChanged: loading
                                  ? null
                                  : (val) {
                                setState(() => selectedEntryDate = val);
                                _applyLocalDateFilterFromState();
                              },
                            ),
                          ),
                        ),

                        SizedBox(width: s(10)),

                        _LightButton(
                          ui: ui,
                          icon: Icons.refresh_rounded,
                          label: "Actualiser",
                          onTap: loading ? null : _loadAll,
                        ),
                      ],
                    ),
                  ),

                  // ===== KPI CARDS : 6 alignées pleine largeur =====
                  Padding(
                    padding: EdgeInsets.fromLTRB(s(18), s(14), s(18), s(12)),
                    child: Row(
                      children: [
                        Expanded(
                          child: _KpiCardLight(
                            ui: ui,
                            title: "Relevé restant",
                            value: remainingDamage.toString(),
                            icon: Icons.car_crash_rounded,
                            tone: const Color(0xFF0EA5E9),
                          ),
                        ),
                        SizedBox(width: s(10)),
                        Expanded(
                          child: _KpiCardLight(
                            ui: ui,
                            title: "Carcheck restant",
                            value: remainingCarcheck.toString(),
                            icon: Icons.fact_check_rounded,
                            tone: const Color(0xFF8B5CF6),
                          ),
                        ),
                        SizedBox(width: s(10)),
                        Expanded(
                          child: _KpiCardLight(
                            ui: ui,
                            title: "Photo restant",
                            value: remainingPhoto.toString(),
                            icon: Icons.photo_camera_rounded,
                            tone: const Color(0xFFEC4899),
                          ),
                        ),
                        SizedBox(width: s(10)),
                        Expanded(
                          child: _KpiCardLight(
                            ui: ui,
                            title: "Équipement restant",
                            value: remainingEquipment.toString(),
                            icon: Icons.build_circle_rounded,
                            tone: const Color(0xFF10B981),
                          ),
                        ),
                        SizedBox(width: s(10)),
                        Expanded(
                          child: _KpiCardLight(
                            ui: ui,
                            title: "Aviloo restant",
                            value: remainingAviloo.toString(),
                            icon: Icons.science_rounded,
                            tone: const Color(0xFFF59E0B),
                          ),
                        ),
                        SizedBox(width: s(10)),
                        Expanded(
                          child: _KpiCardLight(
                            ui: ui,
                            title: "Validés (24h)",
                            value: validated24h.toString(),
                            icon: Icons.verified_rounded,
                            tone: const Color(0xFF2563EB),
                            highlight: true,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ===== CONTENT =====
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(s(18), 0, s(18), s(18)),
                      child: LayoutBuilder(
                        builder: (context, c) {
                          final isWide = c.maxWidth >= 900;

                          if (!isWide) {
                            // Sur petit écran, on empile (sinon trop serré)
                            return Column(
                              children: [
                                Expanded(child: _VehicleTableLight(ui)),
                                SizedBox(height: s(12)),
                                SizedBox(
                                  height: s(200),
                                  child: _LastValidatedLightNarrow(
                                    ui: ui,
                                    formatTime: _formatTime,
                                    lastValidated: lastValidated,
                                    loading: loading,
                                  ),
                                ),
                              ],
                            );
                          }

                          // Sur écran large: table principale 3/4+, colonne fine à droite
                          final rightWidth = s(230); // Android plus compact, mais largeur reste utilisée
                          return Row(
                            children: [
                              Expanded(child: _VehicleTableLight(ui)),
                              SizedBox(width: s(12)),
                              SizedBox(
                                width: rightWidth,
                                child: _LastValidatedLightNarrow(
                                  ui: ui,
                                  formatTime: _formatTime,
                                  lastValidated: lastValidated,
                                  loading: loading,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    return wrapped;
  }

  Widget _VehicleTableLight(double ui) {
    double s(double v) => v * ui;

    const card = Colors.white;
    const border = Color(0xFFE5E7EB);
    const textPrimary = Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(s(16)),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: s(18),
            offset: Offset(0, s(10)),
          )
        ],
      ),
      child: Column(
        children: [
          // header
          Container(
            padding: EdgeInsets.symmetric(horizontal: s(14), vertical: s(10)),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F8),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(s(16)),
                topRight: Radius.circular(s(16)),
              ),
              border: const Border(bottom: BorderSide(color: border, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    "Immat • Modèle",
                    style: TextStyle(color: textMuted, fontWeight: FontWeight.w900, fontSize: s(12)),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    "Entrée",
                    style: TextStyle(color: textMuted, fontWeight: FontWeight.w900, fontSize: s(12)),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    "Forecast",
                    style: TextStyle(color: textMuted, fontWeight: FontWeight.w900, fontSize: s(12)),
                  ),
                ),
                Expanded(
                  flex: 8,
                  child: Text(
                    "Opérations",
                    style: TextStyle(color: textMuted, fontWeight: FontWeight.w900, fontSize: s(12)),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: loading
                ? Center(
              child: SizedBox(
                width: s(32),
                height: s(32),
                child: const CircularProgressIndicator(strokeWidth: 3),
              ),
            )
                : vehiclesToProcess.isEmpty
                ? Center(
              child: Text(
                "Aucun véhicule",
                style: TextStyle(color: textMuted, fontWeight: FontWeight.w800, fontSize: s(12)),
              ),
            )
                : ListView.separated(
              padding: EdgeInsets.all(s(12)),
              itemCount: vehiclesToProcess.length,
              separatorBuilder: (_, __) => SizedBox(height: s(8)),
              itemBuilder: (context, index) {
                final v = vehiclesToProcess[index];

                final plate = (v['plate'] ?? '').toString();
                final qrPlate = _sanitizePlateForQr(plate);
                final brand = (v['brand'] ?? '').toString();
                final model = (v['model'] ?? '').toString();
                final entryIso = v['urgency_time'];
                final forecastSales = (v['forecast_sales'] ?? '').toString().trim();
                final hasForecastSales = forecastSales.isNotEmpty;

                final requiredDamage = v['required_damage'] == true;
                final requiredCarcheck = v['required_carcheck'] == true;
                final requiredPhoto = v['required_photo'] == true;
                final requiredEquipment = v['required_equipment'] == true;
                final requiredAviloo = v['required_aviloo'] == true;

                final doneDamage = v['done_damage'] == true;
                final doneCarcheck = v['done_carcheck'] == true;
                final donePhoto = v['done_photo'] == true;
                final doneEquipment = v['done_equipment'] == true;
                final doneAviloo = v['done_aviloo'] == true;

                final damageState = _taskState(requiredTask: requiredDamage, doneTask: doneDamage);
                final carcheckState = _taskState(requiredTask: requiredCarcheck, doneTask: doneCarcheck);
                final photoState = _taskState(requiredTask: requiredPhoto, doneTask: donePhoto);
                final equipmentState = _taskState(requiredTask: requiredEquipment, doneTask: doneEquipment);
                final avilooState = _taskState(requiredTask: requiredAviloo, doneTask: doneAviloo);

                final fullyValidated = v['fully_validated'] == true;
                // deadline calculé mais non affiché (inchangé volontairement)
                final _ = _deadline(entryIso);

                return Container(
                  padding: EdgeInsets.symmetric(horizontal: s(12), vertical: s(10)),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(s(12)),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: Row(
                          children: [
                            Icon(
                              fullyValidated ? Icons.check_circle_rounded : Icons.directions_car_rounded,
                              color: fullyValidated ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                              size: s(18),
                            ),
                            SizedBox(width: s(10)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FrenchPlate(plate: plate, ui: ui),
                                  SizedBox(height: s(4)),
                                  Text(
                                    "${brand.isEmpty ? "" : brand} ${model.isEmpty ? "" : model}".trim().isEmpty
                                        ? "—"
                                        : "${brand.isEmpty ? "" : brand} ${model.isEmpty ? "" : model}".trim(),
                                    style: TextStyle(
                                      color: textMuted,
                                      fontWeight: FontWeight.w700,
                                      fontSize: s(11),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          _formatDate(entryIso),
                          style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: s(12),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: s(8)),
                      Expanded(
                        flex: 3,
                        child: Text(
                          hasForecastSales ? forecastSales : '',
                          style: TextStyle(
                            color: textMuted,
                            fontWeight: FontWeight.w700,
                            fontSize: s(11),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: s(8)),
                      Expanded(
                        flex: 8,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Wrap(
                                spacing: s(8),
                                runSpacing: s(8),
                                children: [
                                  _OpChipLight(ui: ui, label: "Relevé", state: damageState),
                                  _OpChipLight(ui: ui, label: "Carcheck", state: carcheckState),
                                  _OpChipLight(ui: ui, label: "Photo", state: photoState),
                                  _OpChipLight(ui: ui, label: "Équip.", state: equipmentState),
                                  _OpChipLight(ui: ui, label: "Aviloo", state: avilooState),
                                ],
                              ),
                            ),
                            SizedBox(width: s(10)),
                            qrPlate.isEmpty
                                ? const SizedBox.shrink()
                                : InkWell(
                              onTap: () => _showQrPopup(
                                plate: plate,
                                qrPlate: qrPlate,
                              ),
                              borderRadius: BorderRadius.circular(s(8)),
                              child: Container(
                                padding: EdgeInsets.all(s(4)),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(s(8)),
                                  border: Border.all(color: border),
                                ),
                                child: QrImageView(
                                  data: qrPlate,
                                  version: QrVersions.auto,
                                  size: s(46),
                                  backgroundColor: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ===== MODELS =====
class _DeadlineUI {
  final Color color;
  final String label;
  final String sub;
  const _DeadlineUI({required this.color, required this.label, required this.sub});
}

// ===== WIDGETS LIGHT =====
class _LightButton extends StatelessWidget {
  final double ui;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _LightButton({
    required this.ui,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    double s(double v) => v * ui;

    const border = Color(0xFFE5E7EB);
    const textPrimary = Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    final disabled = onTap == null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(s(12)),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: s(12), vertical: s(10)),
        decoration: BoxDecoration(
          color: disabled ? const Color(0xFFF2F4F8) : Colors.white,
          borderRadius: BorderRadius.circular(s(12)),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Icon(icon, size: s(18), color: disabled ? textMuted : textPrimary),
            SizedBox(width: s(8)),
            Text(
              label,
              style: TextStyle(
                color: disabled ? textMuted : textPrimary,
                fontWeight: FontWeight.w900,
                fontSize: s(12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KpiCardLight extends StatelessWidget {
  final double ui;
  final String title;
  final String value;
  final IconData icon;
  final Color tone;
  final bool highlight;

  const _KpiCardLight({
    required this.ui,
    required this.title,
    required this.value,
    required this.icon,
    required this.tone,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    double s(double v) => v * ui;

    const border = Color(0xFFE5E7EB);
    const textPrimary = Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    return Container(
      padding: EdgeInsets.all(s(14)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(s(16)),
        border: Border.all(color: highlight ? tone.withValues(alpha: 0.50) : border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: s(16),
            offset: Offset(0, s(10)),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: s(40),
            height: s(40),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(s(12)),
            ),
            child: Icon(icon, color: tone, size: s(22)),
          ),
          SizedBox(width: s(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textMuted, fontWeight: FontWeight.w900, fontSize: s(12)),
                ),
                SizedBox(height: s(8)),
                Text(
                  value,
                  style: TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: s(26), height: 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeadlineChipLight extends StatelessWidget {
  final double ui;
  final _DeadlineUI deadline;

  const _DeadlineChipLight({required this.ui, required this.deadline});

  @override
  Widget build(BuildContext context) {
    double s(double v) => v * ui;

    const textPrimary = Color(0xFF0F172A);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: s(10), vertical: s(8)),
      decoration: BoxDecoration(
        color: deadline.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: deadline.color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: s(8), height: s(8), decoration: BoxDecoration(color: deadline.color, shape: BoxShape.circle)),
          SizedBox(width: s(8)),
          Text(
            deadline.label,
            style: TextStyle(color: deadline.color, fontWeight: FontWeight.w900, fontSize: s(11)),
          ),
          SizedBox(width: s(6)),
          Text(
            deadline.sub,
            style: TextStyle(color: textPrimary, fontWeight: FontWeight.w800, fontSize: s(11)),
          ),
        ],
      ),
    );
  }
}

class _OpChipLight extends StatelessWidget {
  final double ui;
  final String label;
  final String state;

  const _OpChipLight({required this.ui, required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    double s(double v) => v * ui;

    const border = Color(0xFFE5E7EB);
    const textPrimary = Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    late Color tone;
    late Color bg;
    late String text;
    late IconData icon;

    switch (state) {
      case "done":
        tone = const Color(0xFF16A34A);
        bg = tone.withValues(alpha: 0.12);
        text = "Fait";
        icon = Icons.check_rounded;
        break;
      case "missing":
        tone = const Color(0xFFF59E0B);
        bg = tone.withValues(alpha: 0.12);
        text = "À faire";
        icon = Icons.schedule_rounded;
        break;
      default:
        tone = const Color(0xFF94A3B8);
        bg = const Color(0xFFF2F4F8);
        text = "Non";
        icon = Icons.remove_rounded;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: s(10), vertical: s(8)),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: state == "not_required" ? border : tone.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: s(14), color: state == "not_required" ? textMuted : tone),
          SizedBox(width: s(6)),
          Text(
            label,
            style: TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: s(11)),
          ),
          SizedBox(width: s(8)),
          Text(
            text,
            style: TextStyle(color: state == "not_required" ? textMuted : tone, fontWeight: FontWeight.w900, fontSize: s(11)),
          ),
        ],
      ),
    );
  }
}

class _LastValidatedLightNarrow extends StatelessWidget {
  final double ui;
  final String Function(dynamic iso) formatTime;
  final List<Map<String, dynamic>> lastValidated;
  final bool loading;

  const _LastValidatedLightNarrow({
    required this.ui,
    required this.formatTime,
    required this.lastValidated,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    double s(double v) => v * ui;

    const card = Colors.white;
    const border = Color(0xFFE5E7EB);
    const textPrimary = Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(s(16)),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          // header très compact
          Container(
            padding: EdgeInsets.symmetric(horizontal: s(10), vertical: s(8)),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F8),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(s(16)), topRight: Radius.circular(s(16))),
              border: const Border(bottom: BorderSide(color: border, width: 1)),
            ),
            child: Row(
              children: [
                Icon(Icons.history_rounded, color: textMuted, size: s(16)),
                SizedBox(width: s(8)),
                Text(
                  "Validés",
                  style: TextStyle(color: textMuted, fontWeight: FontWeight.w900, fontSize: s(12)),
                ),
              ],
            ),
          ),

          Expanded(
            child: loading
                ? const SizedBox.shrink()
                : ListView.builder(
              padding: EdgeInsets.fromLTRB(s(8), s(8), s(8), s(8)),
              itemCount: lastValidated.length,
              itemBuilder: (context, index) {
                final v = lastValidated[index];
                final plate = (v['plate'] ?? '').toString();
                final time = formatTime(v['last_validation_at']);

                return Container(
                  margin: EdgeInsets.only(bottom: s(6)),
                  padding: EdgeInsets.symmetric(horizontal: s(8), vertical: s(8)),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(s(12)),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          plate,
                          style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w900,
                            fontSize: s(11),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: s(8)),
                      Text(
                        time,
                        style: TextStyle(
                          color: textMuted,
                          fontWeight: FontWeight.w900,
                          fontSize: s(11),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class EuStars extends StatelessWidget {
  final double size;
  final Color color;

  const EuStars({
    super.key,
    required this.size,
    this.color = const Color(0xFFFFD700),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _EuStarsPainter(color: color),
      ),
    );
  }
}

class _EuStarsPainter extends CustomPainter {
  final Color color;
  _EuStarsPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Rayon du cercle des étoiles (comme le drapeau UE)
    final ringRadius = size.width * 0.34;

    // Taille des étoiles
    final outerR = size.width * 0.08;
    final innerR = outerR * 0.45;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (int i = 0; i < 12; i++) {
      // -90° pour commencer en haut
      final a = (-math.pi / 2) + (i * 2 * math.pi / 12);
      final starCenter = center +
          Offset(
            ringRadius * math.cos(a),
            ringRadius * math.sin(a),
          );

      final path = _starPath(
        center: starCenter,
        outerRadius: outerR,
        innerRadius: innerR,
        points: 5,
        rotation: -math.pi / 2, // étoile "droite"
      );

      canvas.drawPath(path, paint);
    }
  }

  Path _starPath({
    required Offset center,
    required double outerRadius,
    required double innerRadius,
    int points = 5,
    double rotation = 0,
  }) {
    final path = Path();
    final step = math.pi / points; // 10 segments pour 5 branches

    for (int i = 0; i < points * 2; i++) {
      final r = (i.isEven) ? outerRadius : innerRadius;
      final angle = rotation + (i * step);
      final p = Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _EuStarsPainter oldDelegate) => oldDelegate.color != color;
}

class FrenchPlate extends StatelessWidget {
  final String plate;
  final bool compact; // true = version petite (colonne Validés)
  final double? height;
  final double ui;

  const FrenchPlate({
    super.key,
    required this.plate,
    this.compact = false,
    this.height,
    this.ui = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    double s(double v) => v * ui;

    final baseH = height ?? (compact ? 28.0 : 34.0);
    final h = s(baseH);

    return Container(
      height: h,
      padding: EdgeInsets.all(s(2)),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0B0B), // bord noir
        borderRadius: BorderRadius.circular(s(6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: s(8),
            offset: Offset(0, s(4)),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(s(5)),
        child: Row(
          children: [
            // Bande bleue (EU + F)
            Container(
              width: s(compact ? 22 : 26),
              color: const Color(0xFF003399),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  EuStars(
                    size: s(compact ? 14 : 16),
                    color: const Color(0xFFFFD700),
                  ),
                  SizedBox(height: s(2)),
                  Text(
                    "F",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: s(compact ? 10 : 12),
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),

            // Partie blanche (texte plaque)
            Expanded(
              child: Container(
                color: const Color(0xFFF7F7F7),
                alignment: Alignment.center,
                padding: EdgeInsets.symmetric(horizontal: s(8)),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    plate,
                    maxLines: 1,
                    style: TextStyle(
                      color: const Color(0xFF111827),
                      fontWeight: FontWeight.w900,
                      fontSize: s(compact ? 14 : 18),
                      letterSpacing: s(compact ? 1.2 : 1.6),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
