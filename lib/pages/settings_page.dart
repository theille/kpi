import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as ex;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Structure renvoyée par une cellule d'opération :
/// - required : true si "A FAIRE"
/// - doneIso  : date ISO YYYY-MM-DD si la cellule contient une date (donc déjà fait)
/// - hasSomething : la cellule contient une info ("A FAIRE" ou une date ou autre valeur)
class _Op {
  final bool required;
  final String? doneIso; // "YYYY-MM-DD"
  final bool hasSomething;

  const _Op({
    required this.required,
    required this.doneIso,
    required this.hasSomething,
  });
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _adminPassword = "987654321"; // provisoire
  bool _unlocked = false;

  bool _importing = false;
  String _status = "";

  final _dateCtrl = TextEditingController();

  // ===== THEME COMMUN =====
  static const _bg = Color(0xFFF6F7FB);
  static const _card = Colors.white;
  static const _card2 = Color(0xFFF2F4F8);
  static const _border = Color(0xFFE5E7EB);
  static const _text = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);
  static const _accent = Color(0xFF2563EB);

  @override
  void initState() {
    super.initState();
    _dateCtrl.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    super.dispose();
  }

  Future<void> _askPassword() async {
    final ctrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Accès sécurisé"),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: "Mot de passe",
              border: OutlineInputBorder(),
            ),
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

    if (ok != true) return;

    if (ctrl.text.trim() == _adminPassword) {
      setState(() => _unlocked = true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Accès autorisé")),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Mot de passe incorrect")),
      );
    }
  }

  Future<void> _importKpi() async {
    setState(() {
      _importing = true;
      _status = "Sélection du fichier…";
    });

    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'csv'],
        withData: true,
      );

      if (res == null || res.files.isEmpty) {
        setState(() {
          _importing = false;
          _status = "Import annulé.";
        });
        return;
      }

      final file = res.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception("Impossible de lire le fichier (bytes null).");
      }

      final ext = (file.extension ?? "").toLowerCase();
      final kpiDate = _dateCtrl.text.trim(); // yyyy-MM-dd

      List<Map<String, dynamic>> rows;
      if (ext == "xlsx") {
        rows = _parseXlsx(bytes, kpiDate);
      } else if (ext == "csv") {
        rows = _parseCsv(bytes, kpiDate);
      } else {
        throw Exception("Extension non supportée: .$ext");
      }

      if (rows.isEmpty) {
        throw Exception("Aucune ligne KPI détectée.");
      }

      final supabase = Supabase.instance.client;

      setState(() => _status = "Suppression KPI existant…");
      await supabase.from('kpi_vehicles').delete().eq('kpi_date', kpiDate);

      setState(() => _status = "Insertion ${rows.length} lignes…");
      const batchSize = 200;
      for (var i = 0; i < rows.length; i += batchSize) {
        final batch = rows.sublist(i, (i + batchSize).clamp(0, rows.length));
        await supabase.from('kpi_vehicles').insert(batch);
      }

      setState(() {
        _importing = false;
        _status = "✅ Import OK : ${rows.length} véhicules.";
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Import réussi (${rows.length} véhicules)")),
      );
    } catch (e) {
      setState(() {
        _importing = false;
        _status = "❌ Erreur import : $e";
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur import : $e")),
      );
    }
  }

  // ---------- PARSING KPI ----------

  bool _isAFaire(dynamic v) {
    var s = (v ?? '').toString();

    // normalisation Excel: espaces insécables, tabs, retours, multi-espaces
    s = s.replaceAll('\u00A0', ' '); // NBSP -> espace normal
    s = s.replaceAll(RegExp(r'\s+'), ' '); // compact
    s = s.trim().toUpperCase();

    // accepte A FAIRE, AFAIRE, A  FAIRE, A-FAIRE, etc.
    return RegExp(r'^A[\s\-]*FAIRE$').hasMatch(s);
  }

  /// Retourne une date ISO "YYYY-MM-DD" ou null.
  /// Supporte:
  /// - DateTime (Excel peut renvoyer un DateTime)
  /// - nombre (serial date Excel)
  /// - "YYYY-MM-DD"
  /// - "DD/MM/YYYY"
  /// - "YYYY-MM-DD HH:MM:SS"
  /// - "DD/MM/YYYY HH:MM(:SS)"
  String? _toIsoDateDynamic(dynamic input) {
    if (input == null) return null;

    // 1) Si déjà DateTime
    if (input is DateTime) {
      final yyyy = input.year.toString().padLeft(4, '0');
      final mm = input.month.toString().padLeft(2, '0');
      final dd = input.day.toString().padLeft(2, '0');
      return "$yyyy-$mm-$dd";
    }

    // 2) Si nombre Excel (serial date)
    if (input is num) {
      final base = DateTime(1899, 12, 30);
      final dt = base.add(Duration(days: input.floor()));
      final yyyy = dt.year.toString().padLeft(4, '0');
      final mm = dt.month.toString().padLeft(2, '0');
      final dd = dt.day.toString().padLeft(2, '0');
      return "$yyyy-$mm-$dd";
    }

    // 3) Texte
    final s0 = input.toString().trim();
    if (s0.isEmpty) return null;

    // Supprime l'heure si présente
    final s = s0.split(' ').first;

    // Format ISO direct
    final iso = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (iso.hasMatch(s)) return s;

    // Format FR DD/MM/YYYY
    final fr = RegExp(r'^(\d{1,2})\/(\d{1,2})\/(\d{4})$');
    final m = fr.firstMatch(s);
    if (m != null) {
      final dd = m.group(1)!.padLeft(2, '0');
      final mm = m.group(2)!.padLeft(2, '0');
      final yyyy = m.group(3)!;
      return "$yyyy-$mm-$dd";
    }

    // Dernière tentative : parse automatique
    try {
      final dt = DateTime.parse(s0);
      final yyyy = dt.year.toString().padLeft(4, '0');
      final mm = dt.month.toString().padLeft(2, '0');
      final dd = dt.day.toString().padLeft(2, '0');
      return "$yyyy-$mm-$dd";
    } catch (_) {}

    return null;
  }

  String _cellString(dynamic v) {
    var s = (v ?? '').toString();
    s = s.replaceAll('\u00A0', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.trim();
  }

  _Op _parseOp(dynamic v) {
    final s = _cellString(v);
    if (s.isEmpty) return const _Op(required: false, doneIso: null, hasSomething: false);

    if (_isAFaire(s)) {
      return const _Op(required: true, doneIso: null, hasSomething: true);
    }

    final iso = _toIsoDateDynamic(v);
    if (iso != null) {
      return _Op(required: false, doneIso: iso, hasSomething: true);
    }

    return const _Op(required: false, doneIso: null, hasSomething: true);
  }


  // ✅ Choisit la feuille KPI automatiquement (pas juste "2e feuille")
  ex.Sheet? _pickKpiSheet(ex.Excel excel) {
    final tables = excel.tables;
    if (tables.isEmpty) return null;

    for (final entry in tables.entries) {
      final sheet = entry.value;
      if (sheet.rows.isEmpty) continue;

      final header = sheet.rows.first.map((c) => _cellString(c?.value)).toList();
      final lower = header.map((h) => h.toLowerCase()).toList();

      final hasImmat = lower.contains('immat');
      final hasMarque = lower.contains('marque');
      final hasModele = lower.contains('modele');

      if (hasImmat && hasMarque && hasModele) {
        return sheet;
      }
    }

    // fallback: si on ne trouve pas, on tente la 2e si dispo
    final list = tables.values.toList();
    if (list.length >= 2) return list[1];
    return list.first;
  }

  List<Map<String, dynamic>> _parseXlsx(List<int> bytes, String kpiDate) {
    final excel = ex.Excel.decodeBytes(bytes);

    final sheet = _pickKpiSheet(excel);
    if (sheet == null || sheet.rows.isEmpty) return [];

    final header = sheet.rows.first
        .map((c) => _cellString(c?.value))
        .toList();

    String _norm(String s) {
      return s
          .replaceAll('\u00A0', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .toLowerCase()
          .replaceAll('é', 'e')
          .replaceAll('è', 'e')
          .replaceAll('ê', 'e')
          .replaceAll('à', 'a')
          .replaceAll('ç', 'c');
    }

    int idx(String name) => header.indexWhere((h) => _norm(h) == _norm(name));

    // Colonnes attendues
    final iPlate = idx("Immat");
    final iBrand = idx("MARQUE");
    final iModel = idx("Modele");
    final iSite = idx("Site");
    final iEntry = idx("Entrée");
    final iAmPm = idx("AM/PM");
    final iForecast = idx("Forecast Ventes");

    final iPhoto = idx("AOS");
    final iDamage = idx("Proovstation");
    final iEquip = idx("Equipment");
    final iCar = idx("CarCheck");

    final iRvoDamage = idx("RVO Dégâts");
    final iRvoEquip = idx("RVO Equpmt");

    final iAviloo = idx("AVILOO");

    final requiredIdx = [
      iPlate,
      iBrand,
      iModel,
      iSite,
      iEntry,
      iAmPm,
      iForecast,
      iPhoto,
      iDamage,
      iEquip,
      iCar,
      iRvoDamage,
      iRvoEquip,
      iAviloo,
    ];

    if (requiredIdx.any((i) => i < 0)) {
      throw Exception(
        "Colonnes KPI introuvables. Vérifie les en-têtes exacts :\n"
            "Immat, MARQUE, Modele, Site, Entrée, AM/PM, Forecast Ventes,\n"
            "AOS, Proovstation, Equipment, CarCheck, RVO Dégâts, RVO Equpmt, AVILOO",
      );
    }

    final out = <Map<String, dynamic>>[];

    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      if (row.isEmpty) continue;

      final plateRaw = _cellString(row[iPlate]?.value);
      if (plateRaw.isEmpty) continue;

      final brand = _cellString(row[iBrand]?.value);
      final model = _cellString(row[iModel]?.value);
      final site = _cellString(row[iSite]?.value);
      final ampm = _cellString(row[iAmPm]?.value);
      final forecast = _cellString(row[iForecast]?.value);
      final opAviloo = _parseOp(row[iAviloo]?.value);

      // ✅ IMPORTANT: on lit la valeur brute (DateTime possible)
      final entryIso = _toIsoDateDynamic(row[iEntry]?.value);

      // Opérations normales
      final opPhoto = _parseOp(row[iPhoto]?.value);
      final opCar = _parseOp(row[iCar]?.value);

      final opDamageNormal = _parseOp(row[iDamage]?.value);
      final opEquipNormal = _parseOp(row[iEquip]?.value);

      // RVO : si RVO a une info (A FAIRE ou date), il remplace la colonne normale
      final opDamageRvo = _parseOp(row[iRvoDamage]?.value);
      final opEquipRvo = _parseOp(row[iRvoEquip]?.value);

      final useRvoDamage = opDamageRvo.required || opDamageRvo.doneIso != null;
      final useRvoEquip = opEquipRvo.required || opEquipRvo.doneIso != null;

      final finalDamage = useRvoDamage ? opDamageRvo : opDamageNormal;
      final finalEquip = useRvoEquip ? opEquipRvo : opEquipNormal;

      out.add({
        'kpi_date': kpiDate,
        'plate': plateRaw.toUpperCase(),
        'brand': brand,
        'model': model,
        'site': site,
        'am_pm': ampm,
        'forecast_sales': forecast,
        'required_aviloo': opAviloo.required,
        'aviloo_done_date': opAviloo.doneIso,
        'entry_time': entryIso,

        // requirements
        'required_photo': opPhoto.required,
        'required_damage': finalDamage.required,
        'required_equipment': finalEquip.required,
        'required_carcheck': opCar.required,

        // done dates (si date dans la cellule)
        'photo_done_date': opPhoto.doneIso,
        'damage_done_date': finalDamage.doneIso,
        'equipment_done_date': finalEquip.doneIso,
        'carcheck_done_date': opCar.doneIso,

        // sources
        'damage_source': useRvoDamage ? 'rvo' : 'proovstation',
        'equipment_source': useRvoEquip ? 'rvo' : 'equipment',
      });
    }

    return out;
  }

  List<Map<String, dynamic>> _parseCsv(List<int> bytes, String kpiDate) {
    final text = utf8.decode(bytes);
    final rows = const CsvToListConverter().convert(text, eol: '\n');
    if (rows.isEmpty) return [];

    final header = rows.first.map((e) => e.toString().trim()).toList();
    int idx(String name) => header.indexWhere((h) => h.toLowerCase() == name.toLowerCase());

    final iPlate = idx("Immat");
    final iBrand = idx("MARQUE");
    final iModel = idx("Modele");
    final iSite = idx("Site");
    final iEntry = idx("Entrée");
    final iAmPm = idx("AM/PM");
    final iForecast = idx("Forecast Ventes");

    final iPhoto = idx("AOS");
    final iDamage = idx("Proovstation");
    final iEquip = idx("Equipment");
    final iCar = idx("CarCheck");

    final iRvoDamage = idx("RVO Dégâts");
    final iRvoEquip = idx("RVO Equpmt");

    final iAviloo = idx("AVILOO");

    final requiredIdx = [
      iPlate,
      iBrand,
      iModel,
      iSite,
      iEntry,
      iAmPm,
      iForecast,
      iPhoto,
      iDamage,
      iEquip,
      iCar,
      iRvoDamage,
      iRvoEquip,
      iAviloo,
    ];

    if (requiredIdx.any((i) => i < 0)) {
      throw Exception(
        "Colonnes KPI introuvables dans le CSV. En-têtes attendus :\n"
            "Immat, MARQUE, Modele, Site, Entrée, AM/PM, Forecast Ventes,\n"
            "AOS, Proovstation, Equipment, CarCheck, RVO Dégâts, RVO Equpmt, AVILOO",
      );
    }

    final out = <Map<String, dynamic>>[];

    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= iPlate) continue;

      final plateRaw = row[iPlate].toString().trim();
      if (plateRaw.isEmpty) continue;

      final brand = row[iBrand].toString().trim();
      final model = row[iModel].toString().trim();
      final site = row[iSite].toString().trim();
      final ampm = row[iAmPm].toString().trim();
      final forecast = row[iForecast].toString().trim();
      final aviloo = row[iAviloo].toString().trim();

      // ✅ CSV: valeur directe (pas de .value)
      final entryIso = _toIsoDateDynamic(row[iEntry]);

      final opPhoto = _parseOp(row[iPhoto]);
      final opCar = _parseOp(row[iCar]);

      final opDamageNormal = _parseOp(row[iDamage]);
      final opEquipNormal = _parseOp(row[iEquip]);

      final opDamageRvo = _parseOp(row[iRvoDamage]);
      final opEquipRvo = _parseOp(row[iRvoEquip]);

      final opAviloo = _parseOp(row[iAviloo]);

      final useRvoDamage = opDamageRvo.required || opDamageRvo.doneIso != null;
      final useRvoEquip = opEquipRvo.required || opEquipRvo.doneIso != null;

      final finalDamage = useRvoDamage ? opDamageRvo : opDamageNormal;
      final finalEquip = useRvoEquip ? opEquipRvo : opEquipNormal;

      out.add({
        'kpi_date': kpiDate,
        'plate': plateRaw.toUpperCase(),
        'brand': brand,
        'model': model,
        'site': site,
        'am_pm': ampm,
        'forecast_sales': forecast,
        'aviloo': aviloo,
        'entry_time': entryIso,

        'required_photo': opPhoto.required,
        'required_damage': finalDamage.required,
        'required_equipment': finalEquip.required,
        'required_carcheck': opCar.required,
        'required_aviloo': opAviloo.required,


        'photo_done_date': opPhoto.doneIso,
        'damage_done_date': finalDamage.doneIso,
        'equipment_done_date': finalEquip.doneIso,
        'carcheck_done_date': opCar.doneIso,
        'aviloo_done_date': opAviloo.doneIso,

        'damage_source': useRvoDamage ? 'rvo' : 'proovstation',
        'equipment_source': useRvoEquip ? 'rvo' : 'equipment',
      });
    }

    return out;
  }

  Color _statusTone(String s) {
    if (s.startsWith("✅")) return const Color(0xFF16A34A);
    if (s.startsWith("❌")) return const Color(0xFFEF4444);
    if (s.toLowerCase().contains("insertion") || s.toLowerCase().contains("suppression")) {
      return const Color(0xFFF59E0B);
    }
    return _muted;
  }

  @override
  Widget build(BuildContext context) {
    final locked = !_unlocked;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: _card,
        foregroundColor: _text,
        title: const Text(
          "Paramètres",
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          if (locked)
            IconButton(
              onPressed: _askPassword,
              icon: const Icon(Icons.lock_rounded),
              tooltip: "Déverrouiller",
            ),
          if (!locked)
            IconButton(
              onPressed: () => setState(() => _unlocked = false),
              icon: const Icon(Icons.lock_open_rounded),
              tooltip: "Verrouiller",
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
              // ===== CARD: Import KPI =====
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.upload_file_rounded, color: _accent),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            "Import KPI",
                            style: TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                        ),
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
                                  color: locked ? const Color(0xFFEF4444) : const Color(0xFF16A34A),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                locked ? "Verrouillé" : "Déverrouillé",
                                style: const TextStyle(color: _muted, fontWeight: FontWeight.w900, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _dateCtrl,
                      enabled: !_importing,
                      decoration: InputDecoration(
                        labelText: "Date KPI (yyyy-MM-dd)",
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
                        prefixIcon: const Icon(Icons.calendar_month_rounded),
                      ),
                      style: const TextStyle(color: _text, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 12),
                    if (locked)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFFED7AA)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.lock_rounded, color: Color(0xFF9A3412)),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "Déverrouille avec le cadenas pour importer.",
                                style: TextStyle(color: Color(0xFF9A3412), fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: _importing ? null : _importKpi,
                        icon: _importing
                            ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                            : const Icon(Icons.upload_file_rounded),
                        label: Text(_importing ? "Import en cours…" : "Importer un KPI (XLSX / CSV)"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          textStyle: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (_status.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _card2,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _border),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(top: 4),
                              decoration: BoxDecoration(
                                color: _statusTone(_status),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _status,
                                style: const TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // ===== CARD: Aide Colonnes =====
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Format attendu",
                      style: TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 14),
                    ),
                    SizedBox(height: 10),
                    Text(
                      "Colonnes attendues (feuille KPI) :\n"
                          "Immat, MARQUE, Modele, Site, Entrée, AM/PM, Forecast Ventes,\n"
                          "AOS, Proovstation, Equipment, CarCheck, RVO Dégâts, RVO Equpmt, AVILOO\n\n"
                          "Règles :\n"
                          "- \"A FAIRE\" => opération requise\n"
                          "- une date => opération déjà faite (stockée)\n"
                          "- RVO remplace Proovstation/Equipment si RVO contient A FAIRE ou une date",
                      style: TextStyle(color: _muted, fontWeight: FontWeight.w700, fontSize: 12, height: 1.35),
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
