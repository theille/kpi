import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'plate_scan_page.dart';
import '../state/site_prefs.dart';

class ValidationKpiPage extends StatefulWidget {
  const ValidationKpiPage({super.key});

  @override
  State<ValidationKpiPage> createState() => _ValidationKpiPageState();
}

class _ValidationKpiPageState extends State<ValidationKpiPage> {
  final TextEditingController plateController = TextEditingController();
  bool _isValidating = false;

  // ====== LISTE KPI (comme Display) ======
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> vehiclesToProcess = [];
  bool _loadingList = true;
  RealtimeChannel? _channel;

  static const Duration kMaxDelay = Duration(hours: 48);

  // ====== THEME CLAIR PRO (cohérent DisplayPage) ======
  static const _bg = Color(0xFFF6F7FB);
  static const _card = Colors.white;
  static const _card2 = Color(0xFFF2F4F8);
  static const _border = Color(0xFFE5E7EB);
  static const _text = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);
  static const _accent = Color(0xFF2563EB);

  // ====== LOGIQUE INCHANGÉE ======

  String normalizePlate(String input) {
    return input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  // Distance de Levenshtein
  int levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    final m = s.length;
    final n = t.length;

    List<int> prev = List.generate(n + 1, (j) => j);
    List<int> curr = List.filled(n + 1, 0);

    for (int i = 1; i <= m; i++) {
      curr[0] = i;
      for (int j = 1; j <= n; j++) {
        final cost = (s[i - 1] == t[j - 1]) ? 0 : 1;
        curr[j] = [
          curr[j - 1] + 1,
          prev[j] + 1,
          prev[j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[n];
  }

  Future<bool> confirmPlateDialog({
    required String typed,
    required String suggested,
  }) async {
    await HapticFeedback.vibrate();
    await Future.delayed(const Duration(milliseconds: 80));
    await HapticFeedback.vibrate();

    if (!mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Confirmer l’immatriculation"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Une plaque très proche a été trouvée dans le KPI :"),
              const SizedBox(height: 12),
              Text("Saisie :  $typed", style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text("KPI :      $suggested", style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text("Valider la plaque KPI ?"),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Annuler"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Valider"),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> validateVehicle(List<String> tasksUi) async {
    final selectedSite = await SitePrefs.getSite();
    final plateRaw = plateController.text.trim();
    final plateNorm = normalizePlate(plateRaw);

    if (plateNorm.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Veuillez saisir une plaque')),
      );
      return;
    }

    // Mapping UI -> backend (inchangé)
    final tasksBackend = tasksUi.map((t) {
      final lower = t.toLowerCase();

      if (lower.contains('option') || lower.contains('equip')) return 'equipment';
      if (lower.contains('relev')) return 'damage';
      if (lower.contains('carcheck')) return 'carcheck';
      if (lower.contains('photo')) return 'photo';
      if (lower.contains('aviloo')) return 'aviloo';

      return t;
    }).toList();

    try {
      final today = DateTime.now().toUtc();
      final kpiDate = "${today.year.toString().padLeft(4, '0')}-"
          "${today.month.toString().padLeft(2, '0')}-"
          "${today.day.toString().padLeft(2, '0')}";

      var q = supabase
          .from('kpi_vehicles')
          .select('plate')
          .eq('kpi_date', kpiDate);

      if (selectedSite != null && selectedSite.toString().trim().isNotEmpty) {
        q = q.ilike('site', '%$selectedSite%');
      }

      final rows = await q;

      final plates = (rows as List)
          .map((e) => (e['plate'] ?? '').toString())
          .where((p) => p.isNotEmpty)
          .toList();

      // 1) Match EXACT
      String? matchedPlate;
      for (final p in plates) {
        if (normalizePlate(p) == plateNorm) {
          matchedPlate = p;
          break;
        }
      }

      // 2) Match très proche (distance = 1)
      if (matchedPlate == null) {
        final candidates = <String>[];

        for (final p in plates) {
          final n = normalizePlate(p);
          if (n.length == plateNorm.length && levenshtein(plateNorm, n) == 1) {
            candidates.add(p);
          }
        }

        if (candidates.length == 1) {
          final suggested = candidates.first;
          final ok = await confirmPlateDialog(
            typed: plateRaw.toUpperCase(),
            suggested: suggested,
          );
          if (!ok) return;
          matchedPlate = suggested;
        } else if (candidates.length > 1) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Plusieurs plaques proches trouvées. Merci de préciser la saisie.")),
          );
          return;
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Plaque introuvable dans le KPI du jour")),
          );
          return;
        }
      }

      // remet plaque KPI officielle
      plateController.text = matchedPlate;

      await supabase.from('validations').insert({
        'kpi_date': kpiDate,
        'plate': matchedPlate,
        'tasks_done': tasksBackend,
        'operator_name': null,
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Validation envoyée au serveur')),
      );

      plateController.clear();

      // bonus UX: refresh liste après validation
      _loadVehiclesToday();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur serveur : $e')),
      );
    }
  }

  // ====== LISTE KPI (load + realtime) ======

  @override
  void initState() {
    super.initState();
    _loadVehiclesToday();

    // Temps réel: à chaque validation, on recharge la liste
    _channel = supabase.channel('kpi-validation-realtime')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'validations',
        callback: (_) => _loadVehiclesToday(),
      )
      ..subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) {
      supabase.removeChannel(_channel!);
    }
    plateController.dispose();
    super.dispose();
  }

  Future<void> _loadVehiclesToday() async {
    try {
      setState(() => _loadingList = true);

      // ✅ Filtre par site (comme DisplayPage)
      final selectedSite = await SitePrefs.getSite();
      final todayUtc = DateTime.now().toUtc();
      final kpiDate = "${todayUtc.year.toString().padLeft(4, '0')}-"
          "${todayUtc.month.toString().padLeft(2, '0')}-"
          "${todayUtc.day.toString().padLeft(2, '0')}";

      // 1) Plaques du site sélectionné depuis kpi_vehicles
      var siteQ = supabase
          .from('kpi_vehicles')
          .select('plate')
          .eq('kpi_date', kpiDate);

      if (selectedSite != null && selectedSite.toString().trim().isNotEmpty) {
        siteQ = siteQ.ilike('site', '%$selectedSite%');
      }

      final siteRows = await siteQ;
      final sitePlates = (siteRows as List)
          .map((r) => (r['plate'] ?? '').toString())
          .where((p) => p.isNotEmpty)
          .toSet();

      // 2) Liste “à traiter” du jour (vue)
      final left = await supabase
          .from('vehicle_status_today')
          .select()
          .eq('fully_validated', false)
          .order('urgency_time', ascending: true);

      // 3) Filtre par site (on ne garde que les plaques du site)
      final filtered = (left as List)
          .map((e) => Map<String, dynamic>.from(e))
          .where((v) {
        if (sitePlates.isEmpty) return true; // si site non défini/aucune plaque, pas de filtre dur
        return sitePlates.contains((v['plate'] ?? '').toString());
      })
          .toList();

      if (!mounted) return;
      setState(() {
        vehiclesToProcess = filtered;
        _loadingList = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingList = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur chargement liste : $e")),
      );
    }
  }

  // ====== UI HELPERS ======

  void _showInfoTasks(List<String> tasks) {
    final text = tasks.isEmpty
        ? "Aucune tâche active. Va dans la page de sélection et active au moins une tâche."
        : "Tâches actives :\n• ${tasks.join("\n• ")}";

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _openScanner(List<String> tasks) async {
    if (_isValidating) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlateScanPage(
          onPlateConfirmed: (plate) async {
            if (!mounted) return;

            setState(() {
              plateController.text = plate;
              _isValidating = true;
            });

            HapticFeedback.lightImpact();
            await validateVehicle(tasks);

            if (!mounted) return;
            setState(() => _isValidating = false);
          },
        ),
      ),
    );
  }

  String _taskState({required bool requiredTask, required bool doneTask}) {
    if (!requiredTask) return "not_required";
    return doneTask ? "done" : "missing";
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
      return const _DeadlineUI(color: Color(0xFF94A3B8), label: "—", sub: "date");
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

  // ====== BUILD ======

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    final tasks = appState.getSelectedTasks();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: _card,
        foregroundColor: _text,
        title: const Text(
          'Validation KPI',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: "Voir les tâches actives",
            onPressed: () => _showInfoTasks(tasks),
            icon: const Icon(Icons.info_outline_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ===== HEADER CARD =====
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 16,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.qr_code_scanner_rounded, color: _accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Saisir ou scanner une plaque",
                            style: TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tasks.isEmpty
                                ? "Aucune tâche active."
                                : "Tâches actives : ${tasks.join(", ")}",
                            style: const TextStyle(color: _muted, fontWeight: FontWeight.w700, fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: _card2,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: _border),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _isValidating ? const Color(0xFFF59E0B) : const Color(0xFF22C55E),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isValidating ? "Validation…" : "Prêt",
                            style: const TextStyle(color: _muted, fontWeight: FontWeight.w900, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ===== INPUT CARD =====
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      "Immatriculation",
                      style: TextStyle(color: _muted, fontWeight: FontWeight.w900, fontSize: 12),
                    ),
                    const SizedBox(height: 8),

                    TextField(
                      controller: plateController,
                      textCapitalization: TextCapitalization.characters,
                      enabled: !_isValidating,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                        color: _text,
                      ),
                      decoration: InputDecoration(
                        hintText: "Ex : AB-123-CD",
                        hintStyle: const TextStyle(color: _muted),
                        filled: true,
                        fillColor: _card2,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: _border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: _border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _accent.withValues(alpha: 0.7), width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        prefixIcon: const Icon(Icons.directions_car_rounded),
                        suffixIcon: plateController.text.isEmpty
                            ? null
                            : IconButton(
                          tooltip: "Effacer",
                          onPressed: _isValidating
                              ? null
                              : () {
                            plateController.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) async {
                        if (_isValidating) return;
                        setState(() => _isValidating = true);
                        await validateVehicle(tasks);
                        if (!mounted) return;
                        setState(() => _isValidating = false);
                      },
                    ),

                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isValidating ? null : () => _openScanner(tasks),
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            label: const Text("Scanner"),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _text,
                              side: const BorderSide(color: _border),
                              backgroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              textStyle: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isValidating
                                ? null
                                : () async {
                              setState(() => _isValidating = true);
                              await validateVehicle(tasks);
                              if (!mounted) return;
                              setState(() => _isValidating = false);
                            },
                            icon: _isValidating
                                ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                                : const Icon(Icons.check_rounded),
                            label: Text(_isValidating ? "Validation…" : "Valider"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              textStyle: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ===== TASKS CARD =====
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          "Tâches actives",
                          style: TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 14),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: _card2,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: _border),
                          ),
                          child: Text(
                            "${tasks.length}",
                            style: const TextStyle(color: _muted, fontWeight: FontWeight.w900, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (tasks.isEmpty)
                      const Text(
                        "Aucune tâche sélectionnée.",
                        style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tasks
                            .map(
                              (t) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: _accent.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: _accent.withValues(alpha: 0.25)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.check_circle_rounded, size: 16, color: _accent),
                                const SizedBox(width: 8),
                                Text(
                                  t,
                                  style: const TextStyle(
                                    color: _text,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                            .toList(),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ===== LISTE KPI DU JOUR (comme Display) =====
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Text(
                          "Véhicules à traiter",
                          style: TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 14),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: "Rafraîchir",
                          onPressed: _loadingList ? null : _loadVehiclesToday,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (_loadingList)
                      const Padding(
                        padding: EdgeInsets.all(14),
                        child: Center(
                          child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                        ),
                      )
                    else if (vehiclesToProcess.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          "Aucun véhicule",
                          style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
                        ),
                      )
                    else
                      SizedBox(
                        height: 420, // tu peux augmenter si tu veux voir + de lignes
                        child: ListView.separated(
                          itemCount: vehiclesToProcess.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final v = vehiclesToProcess[index];

                            final plate = (v['plate'] ?? '').toString();
                            final brand = (v['brand'] ?? '').toString();
                            final model = (v['model'] ?? '').toString();
                            final entryIso = v['urgency_time'];

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
                            final dl = _deadline(entryIso);

                            return InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                plateController.text = plate;
                                HapticFeedback.selectionClick();

                                // si tu veux auto-valider au tap, décommente :
                                // if (!_isValidating) {
                                //   setState(() => _isValidating = true);
                                //   validateVehicle(tasks).whenComplete(() {
                                //     if (mounted) setState(() => _isValidating = false);
                                //   });
                                // }

                                setState(() {}); // refresh suffixIcon
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: _border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          fullyValidated ? Icons.check_circle_rounded : Icons.directions_car_rounded,
                                          color: fullyValidated ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            plate,
                                            style: const TextStyle(
                                              color: _text,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 16,
                                              letterSpacing: 0.8,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        _DeadlineChipLight(deadline: dl),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            "${brand.isEmpty ? "" : brand} ${model.isEmpty ? "" : model}".trim().isEmpty
                                                ? "—"
                                                : "${brand.isEmpty ? "" : brand} ${model.isEmpty ? "" : model}".trim(),
                                            style: const TextStyle(
                                              color: _muted,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          _formatDate(entryIso),
                                          style: const TextStyle(
                                            color: _muted,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _OpChipLight(label: "Relevé", state: damageState),
                                        _OpChipLight(label: "Carcheck", state: carcheckState),
                                        _OpChipLight(label: "Photo", state: photoState),
                                        _OpChipLight(label: "Équip.", state: equipmentState),
                                        _OpChipLight(label: "Aviloo", state: avilooState),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ====== MODELS ======
class _DeadlineUI {
  final Color color;
  final String label;
  final String sub;
  const _DeadlineUI({required this.color, required this.label, required this.sub});
}

// ====== WIDGETS (repris du style Display) ======
class _DeadlineChipLight extends StatelessWidget {
  final _DeadlineUI deadline;
  const _DeadlineChipLight({required this.deadline});

  @override
  Widget build(BuildContext context) {
    const textPrimary = Color(0xFF0F172A);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: deadline.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: deadline.color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: deadline.color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(
            deadline.label,
            style: TextStyle(color: deadline.color, fontWeight: FontWeight.w900, fontSize: 11),
          ),
          const SizedBox(width: 6),
          Text(
            deadline.sub,
            style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w800, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _OpChipLight extends StatelessWidget {
  final String label;
  final String state;

  const _OpChipLight({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: state == "not_required" ? border : tone.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: state == "not_required" ? textMuted : tone),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 11),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: state == "not_required" ? textMuted : tone,
              fontWeight: FontWeight.w900,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
