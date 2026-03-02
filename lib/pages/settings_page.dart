// settings_page.dart
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

  // ===== Helpers colonnes souples =====

  String _normalizeHeader(String s) {
    return s
        .replaceAll('\u00A0', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase()
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('ë', 'e')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('ä', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ï', 'i')
        .replaceAll('ô', 'o')
        .replaceAll('ö', 'o')
        .replaceAll('ù', 'u')
        .replaceAll('û', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ç', 'c')
        .replaceAll("'", ' ')
        .replaceAll('-', ' ')
        .replaceAll('/', ' ')
        .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  int _findHeaderIndex(List<String> header, List<String> aliases, {bool required = true}) {
    final normalizedHeader = header.map(_normalizeHeader).toList();
    final normalizedAliases = aliases.map(_normalizeHeader).toList();

    // 1) match exact
    for (final alias in normalizedAliases) {
      final idx = normalizedHeader.indexOf(alias);
      if (idx >= 0) return idx;
    }

    // 2) match partiel
    for (var i = 0; i < normalizedHeader.length; i++) {
      final h = normalizedHeader[i];
      for (final alias in normalizedAliases) {
        if (h.contains(alias) || alias.contains(h)) {
          return i;
        }
      }
    }

    if (required) {
      throw Exception("Colonne introuvable (aliases: ${aliases.join(' / ')})");
    }
    return -1;
  }

  dynamic _cellAt(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) return null;
    return row[index];
  }

  // ============================================================
  // ✅ FIX PRINCIPAL : ne plus dépendre de excel.tables
  // ============================================================

  /// Cherche la ligne d'en-tête dans les N premières lignes (utile si Excel a un titre au dessus).
  /// Retourne l'index de la ligne d'en-tête, ou 0 par défaut.
  int _findHeaderRowIndex(ex.Sheet sheet, {int scanRows = 12}) {
    final limit = sheet.rows.length < scanRows ? sheet.rows.length : scanRows;
    int bestIdx = 0;
    int bestScore = -1;

    for (var r = 0; r < limit; r++) {
      final row = sheet.rows[r];
      if (row.isEmpty) continue;

      final header = row.map((c) => _cellString(c?.value)).toList();
      final normalized = header.map(_normalizeHeader).toList();

      bool hasAny(List<String> aliases) {
        final set = aliases.map(_normalizeHeader).toSet();
        return normalized.any(set.contains);
      }

      final hasPlate = hasAny(['immat', 'immatriculation', 'plaque']);
      final hasBrand = hasAny(['marque']);
      final hasModel = hasAny(['modele', 'modèle', 'model']);
      final hasEntry = hasAny(['entree', 'entrée', 'date entree', 'date d entree']);
      final hasOps = hasAny(['aos', 'proovstation', 'equipment', 'carcheck', 'aviloo', 'rvo']);

      int score = 0;
      if (hasPlate) score++;
      if (hasBrand) score++;
      if (hasModel) score++;
      if (hasEntry) score++;
      if (hasOps) score++;

      if (score > bestScore) {
        bestScore = score;
        bestIdx = r;
      }

      if (score >= 4) return r; // assez fiable
    }

    return bestIdx; // fallback
  }

  /// ✅ Choisit la feuille KPI automatiquement (détection souple) via excel.sheets.
  ex.Sheet? _pickKpiSheet(ex.Excel excel) {
    final sheets = excel.sheets;
    if (sheets.isEmpty) return null;

    // DEBUG (tu peux enlever après)
    // ignore: avoid_print
    print("SHEETS: ${sheets.keys.toList()}");
    // ignore: avoid_print
    print("TABLES: ${excel.tables.keys.toList()}");

    ex.Sheet? best;
    int bestScore = -1;

    for (final entry in sheets.entries) {
      final sheet = entry.value;
      if (sheet.rows.isEmpty) continue;

      // on cherche la meilleure ligne d'en-tête (pas forcément la 1ère)
      final headerRowIdx = _findHeaderRowIndex(sheet);
      final headerRow = sheet.rows[headerRowIdx];

      final header = headerRow.map((c) => _cellString(c?.value)).toList();
      final normalized = header.map(_normalizeHeader).toList();

      bool hasAny(List<String> aliases) {
        final aliasNorm = aliases.map(_normalizeHeader).toSet();
        return normalized.any(aliasNorm.contains);
      }

      final hasPlate = hasAny(['immat', 'immatriculation', 'plaque']);
      final hasBrand = hasAny(['marque']);
      final hasModel = hasAny(['modele', 'modèle', 'model']);
      final hasEntry = hasAny(['entree', 'entrée', 'date entree', 'date d entree']);
      final hasOps = hasAny(['aos', 'proovstation', 'equipment', 'carcheck', 'aviloo', 'rvo']);

      int score = 0;
      if (hasPlate) score++;
      if (hasBrand) score++;
      if (hasModel) score++;
      if (hasEntry) score++;
      if (hasOps) score++;

      if (score > bestScore) {
        bestScore = score;
        best = sheet;
      }

      if (score == 5) return sheet; // parfait
    }

    return best;
  }

  List<Map<String, dynamic>> _parseXlsx(List<int> bytes, String kpiDate) {
    final excel = ex.Excel.decodeBytes(bytes);

    final sheet = _pickKpiSheet(excel);
    if (sheet == null || sheet.rows.isEmpty) return [];

    // ✅ Header pas forcément ligne 0
    final headerRowIdx = _findHeaderRowIndex(sheet);
    final headerRow = sheet.rows[headerRowIdx];

    final header = headerRow.map((c) => _cellString(c?.value)).toList();

    // ✅ Colonnes souples (ordre libre, noms tolérés)
    final iPlate = _findHeaderIndex(header, ['Immat', 'Immatriculation', 'Plaque']);
    final iBrand = _findHeaderIndex(header, ['MARQUE', 'Marque']);
    final iModel = _findHeaderIndex(header, ['Modele', 'Modèle', 'Model']);
    final iSite = _findHeaderIndex(header, ['Site']);
    final iEntry = _findHeaderIndex(header, ['Entrée', 'Entree', 'Date entrée', 'Date entree']);

    // ✅ optionnelle
    final iAmPm = _findHeaderIndex(header, ['AM/PM', 'AM PM', 'AMPM'], required: false);

    final iForecast = _findHeaderIndex(
      header,
      ['Forecast Ventes', 'Forecast', 'Ventes', 'Catégorie ventes', 'Categorie ventes'],
      required: false,
    );

    final iPhoto = _findHeaderIndex(header, ['AOS', 'Photos', 'Photo']);
    final iDamage = _findHeaderIndex(header, ['Proovstation', 'Proov', 'Dégâts', 'Degats'], required: false);
    final iEquip = _findHeaderIndex(header, ['Equipment', 'Equipement', 'Équipement'], required: false);
    final iCar = _findHeaderIndex(header, ['CarCheck', 'Car Check'], required: false);

    final iRvoDamage = _findHeaderIndex(
      header,
      ['RVO Dégâts', 'RVO Degats', 'RVO dégâts', 'RVO degats'],
      required: false,
    );
    final iRvoEquip = _findHeaderIndex(
      header,
      ['RVO Equpmt', 'RVO Equipment', 'RVO Equipement'],
      required: false,
    );

    final iAviloo = _findHeaderIndex(header, ['AVILOO', 'Aviloo'], required: false);

    // (Optionnel) VIN : on le lit si présent, sans bloquer
    final iVin = _findHeaderIndex(header, ['VIN'], required: false);

    final out = <Map<String, dynamic>>[];

    // ⚠️ On commence après la ligne header
    for (var r = headerRowIdx + 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      if (row.isEmpty) continue;

      final plateRaw = _cellString(_cellAt(row, iPlate)?.value);
      if (plateRaw.isEmpty) continue;

      final brand = _cellString(_cellAt(row, iBrand)?.value);
      final model = _cellString(_cellAt(row, iModel)?.value);
      final site = _cellString(_cellAt(row, iSite)?.value);
      final ampm = _cellString(_cellAt(row, iAmPm)?.value); // optionnel -> vide si absent
      final forecast = _cellString(_cellAt(row, iForecast)?.value);
      final opAviloo = _parseOp(_cellAt(row, iAviloo)?.value);

      final vin = _cellString(_cellAt(row, iVin)?.value);

      // ✅ IMPORTANT: support DateTime / texte / nombre
      final entryIso = _toIsoDateDynamic(_cellAt(row, iEntry)?.value);

      // Colonnes opérationnelles (certaines peuvent être absentes)
      final opPhoto = _parseOp(_cellAt(row, iPhoto)?.value);
      final opCar = _parseOp(_cellAt(row, iCar)?.value);

      final opDamageNormal = _parseOp(_cellAt(row, iDamage)?.value);
      final opEquipNormal = _parseOp(_cellAt(row, iEquip)?.value);

      // RVO : si RVO a une info (A FAIRE ou date), il remplace la colonne normale
      final opDamageRvo = _parseOp(_cellAt(row, iRvoDamage)?.value);
      final opEquipRvo = _parseOp(_cellAt(row, iRvoEquip)?.value);

      final useRvoDamage = opDamageRvo.required || opDamageRvo.doneIso != null;
      final useRvoEquip = opEquipRvo.required || opEquipRvo.doneIso != null;

      final finalDamage = useRvoDamage ? opDamageRvo : opDamageNormal;
      final finalEquip = useRvoEquip ? opEquipRvo : opEquipNormal;

      out.add({
        'kpi_date': kpiDate,
        'plate': plateRaw.toUpperCase(),
        'vin': vin.isEmpty ? null : vin, // ✅ n'empêche pas l'insert si colonne existe côté DB
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

    // Cherche un header dans les premières lignes (CSV peut aussi avoir un titre)
    int headerRowIdx = 0;
    int bestScore = -1;
    final scan = rows.length < 12 ? rows.length : 12;

    for (var r = 0; r < scan; r++) {
      final header = rows[r].map((e) => e.toString().trim()).toList();
      final normalized = header.map(_normalizeHeader).toList();

      bool hasAny(List<String> aliases) {
        final set = aliases.map(_normalizeHeader).toSet();
        return normalized.any(set.contains);
      }

      final hasPlate = hasAny(['immat', 'immatriculation', 'plaque']);
      final hasBrand = hasAny(['marque']);
      final hasModel = hasAny(['modele', 'modèle', 'model']);
      final hasEntry = hasAny(['entree', 'entrée', 'date entree', 'date d entree']);
      final hasOps = hasAny(['aos', 'proovstation', 'equipment', 'carcheck', 'aviloo', 'rvo']);

      int score = 0;
      if (hasPlate) score++;
      if (hasBrand) score++;
      if (hasModel) score++;
      if (hasEntry) score++;
      if (hasOps) score++;

      if (score > bestScore) {
        bestScore = score;
        headerRowIdx = r;
      }

      if (score >= 4) {
        headerRowIdx = r;
        break;
      }
    }

    final header = rows[headerRowIdx].map((e) => e.toString().trim()).toList();

    // ✅ Colonnes souples
    final iPlate = _findHeaderIndex(header, ['Immat', 'Immatriculation', 'Plaque']);
    final iBrand = _findHeaderIndex(header, ['MARQUE', 'Marque']);
    final iModel = _findHeaderIndex(header, ['Modele', 'Modèle', 'Model']);
    final iSite = _findHeaderIndex(header, ['Site']);
    final iEntry = _findHeaderIndex(header, ['Entrée', 'Entree', 'Date entrée', 'Date entree']);

    // ✅ optionnelle
    final iAmPm = _findHeaderIndex(header, ['AM/PM', 'AM PM', 'AMPM'], required: false);

    final iForecast = _findHeaderIndex(
      header,
      ['Forecast Ventes', 'Forecast', 'Ventes', 'Catégorie ventes', 'Categorie ventes'],
      required: false,
    );

    final iPhoto = _findHeaderIndex(header, ['AOS', 'Photos', 'Photo']);
    final iDamage = _findHeaderIndex(header, ['Proovstation', 'Proov', 'Dégâts', 'Degats'], required: false);
    final iEquip = _findHeaderIndex(header, ['Equipment', 'Equipement', 'Équipement'], required: false);
    final iCar = _findHeaderIndex(header, ['CarCheck', 'Car Check'], required: false);

    final iRvoDamage = _findHeaderIndex(header, ['RVO Dégâts', 'RVO Degats'], required: false);
    final iRvoEquip = _findHeaderIndex(header, ['RVO Equpmt', 'RVO Equipment', 'RVO Equipement'], required: false);

    final iAviloo = _findHeaderIndex(header, ['AVILOO', 'Aviloo'], required: false);
    final iVin = _findHeaderIndex(header, ['VIN'], required: false);

    final out = <Map<String, dynamic>>[];

    for (var r = headerRowIdx + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= iPlate) continue;

      final plateRaw = _cellString(_cellAt(row, iPlate));
      if (plateRaw.isEmpty) continue;

      final brand = _cellString(_cellAt(row, iBrand));
      final model = _cellString(_cellAt(row, iModel));
      final site = _cellString(_cellAt(row, iSite));
      final ampm = _cellString(_cellAt(row, iAmPm));
      final forecast = _cellString(_cellAt(row, iForecast));

      final vin = _cellString(_cellAt(row, iVin));

      // ✅ CSV: valeur directe
      final entryIso = _toIsoDateDynamic(_cellAt(row, iEntry));

      final opPhoto = _parseOp(_cellAt(row, iPhoto));
      final opCar = _parseOp(_cellAt(row, iCar));

      final opDamageNormal = _parseOp(_cellAt(row, iDamage));
      final opEquipNormal = _parseOp(_cellAt(row, iEquip));

      final opDamageRvo = _parseOp(_cellAt(row, iRvoDamage));
      final opEquipRvo = _parseOp(_cellAt(row, iRvoEquip));

      final opAviloo = _parseOp(_cellAt(row, iAviloo));

      final useRvoDamage = opDamageRvo.required || opDamageRvo.doneIso != null;
      final useRvoEquip = opEquipRvo.required || opEquipRvo.doneIso != null;

      final finalDamage = useRvoDamage ? opDamageRvo : opDamageNormal;
      final finalEquip = useRvoEquip ? opEquipRvo : opEquipNormal;

      out.add({
        'kpi_date': kpiDate,
        'plate': plateRaw.toUpperCase(),
        'vin': vin.isEmpty ? null : vin,
        'brand': brand,
        'model': model,
        'site': site,
        'am_pm': ampm,
        'forecast_sales': forecast,
        'aviloo': _cellString(_cellAt(row, iAviloo)),
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
        backgroundColor: _bg,
        elevation: 0,
        title: const Text("Paramètres / Export KPI"),
        foregroundColor: _text,
        actions: [
          if (locked)
            IconButton(
              tooltip: "Déverrouiller",
              onPressed: _importing ? null : _askPassword,
              icon: const Icon(Icons.lock),
            )
          else
            IconButton(
              tooltip: "Verrouiller",
              onPressed: _importing
                  ? null
                  : () {
                      setState(() => _unlocked = false);
                    },
              icon: const Icon(Icons.lock_open),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Import KPI vers Supabase",
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _text),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    locked
                        ? "🔒 Page verrouillée : clique sur le cadenas pour entrer le mot de passe."
                        : "✅ Page déverrouillée : tu peux importer un fichier KPI (.xlsx ou .csv).",
                    style: const TextStyle(color: _muted),
                  ),
                  const SizedBox(height: 16),

                  // Date KPI
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _card2,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _border),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 18, color: _muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _dateCtrl,
                            enabled: !locked && !_importing,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              labelText: "Date KPI (yyyy-MM-dd)",
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Bouton import
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: locked ? Colors.grey.shade400 : _accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: (locked || _importing) ? null : _importKpi,
                      icon: _importing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.cloud_upload),
                      label: Text(_importing ? "Import en cours…" : "Importer un fichier KPI"),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Status
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: _statusTone(_status)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _status.isEmpty ? "Aucun import lancé." : _status,
                      style: TextStyle(color: _statusTone(_status), fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
