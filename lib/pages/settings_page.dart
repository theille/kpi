// settings_page.dart (version "moins stricte" + debug clair)
// ✅ Supporte fichiers KPI très variables (header pas en 1ère ligne, colonnes manquantes)
// ✅ Ne dépend PAS de excel.tables (utilise excel.sheets)
// ✅ N'échoue pas si certaines colonnes sont absentes (elles deviennent optionnelles)
// ✅ Affiche la vraie erreur Supabase + trouve la ligne fautive si un batch échoue

import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as ex;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        throw Exception("Aucune ligne KPI détectée (header ou colonnes non reconnues).");
      }

      final supabase = Supabase.instance.client;

      setState(() => _status = "Suppression KPI existant…");
      await supabase.from('kpi_vehicles').delete().eq('kpi_date', kpiDate);

      setState(() => _status = "Insertion ${rows.length} lignes…");
      const batchSize = 200;

      for (var i = 0; i < rows.length; i += batchSize) {
        final batch = rows.sublist(i, (i + batchSize).clamp(0, rows.length));

        try {
          await supabase.from('kpi_vehicles').insert(batch);
        } catch (e) {
          // Si un batch échoue, on tente ligne par ligne pour trouver LA ligne fautive
          setState(() => _status =
          "❌ Batch en erreur (lignes ${i + 1} -> ${i + batch.length}). Recherche de la ligne fautive…");

          for (var j = 0; j < batch.length; j++) {
            try {
              await supabase.from('kpi_vehicles').insert(batch[j]);
            } catch (e2) {
              final bad = batch[j];
              throw Exception(
                "Erreur insert à la ligne ${i + j + 1} : $e2\n"
                    "plate=${bad['plate']} entry_time=${bad['entry_time']}\n"
                    "row=$bad",
              );
            }
          }

          rethrow;
        }
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
      String msg = e.toString();

      // Erreurs Supabase plus lisibles
      if (e is PostgrestException) {
        msg = "PostgrestException: ${e.message}\ncode: ${e.code}\ndetails: ${e.details}\nhint: ${e.hint}";
      }

      setState(() {
        _importing = false;
        _status = "❌ Erreur import :\n$msg";
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur import : $msg")),
      );
    }
  }

  // ---------- PARSING KPI ----------

  bool _isAFaire(dynamic v) {
    var s = (v ?? '').toString();
    s = s.replaceAll('\u00A0', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    s = s.trim().toUpperCase();
    return RegExp(r'^A[\s\-]*FAIRE$').hasMatch(s);
  }

  String? _toIsoDateDynamic(dynamic input) {
    if (input == null) return null;

    if (input is DateTime) {
      final yyyy = input.year.toString().padLeft(4, '0');
      final mm = input.month.toString().padLeft(2, '0');
      final dd = input.day.toString().padLeft(2, '0');
      return "$yyyy-$mm-$dd";
    }

    if (input is num) {
      final base = DateTime(1899, 12, 30);
      final dt = base.add(Duration(days: input.floor()));
      final yyyy = dt.year.toString().padLeft(4, '0');
      final mm = dt.month.toString().padLeft(2, '0');
      final dd = dt.day.toString().padLeft(2, '0');
      return "$yyyy-$mm-$dd";
    }

    final s0 = input.toString().trim();
    if (s0.isEmpty) return null;

    final s = s0.split(' ').first;

    final iso = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (iso.hasMatch(s)) return s;

    final fr = RegExp(r'^(\d{1,2})\/(\d{1,2})\/(\d{4})$');
    final m = fr.firstMatch(s);
    if (m != null) {
      final dd = m.group(1)!.padLeft(2, '0');
      final mm = m.group(2)!.padLeft(2, '0');
      final yyyy = m.group(3)!;
      return "$yyyy-$mm-$dd";
    }

    // Dernière tentative
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

    for (final alias in normalizedAliases) {
      final idx = normalizedHeader.indexOf(alias);
      if (idx >= 0) return idx;
    }

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

  // ===== Détection feuille + header ligne =====

  int _findHeaderRowIndexInSheet(ex.Sheet sheet, {int scanRows = 15}) {
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
      final hasModel = hasAny(['modele', 'model', 'modèle']);
      final hasEntry = hasAny(['entree', 'entrée', "date d entree", "date d'entrée", 'date entree', 'date entrée']);
      final hasOps = hasAny(['aos', 'photo', 'photos', 'proov', 'proovstation', 'equipment', 'equipement', 'carcheck', 'aviloo', 'rvo']);

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

      if (score >= 4) return r;
    }

    return bestIdx;
  }

  ex.Sheet? _pickKpiSheet(ex.Excel excel) {
    final sheets = excel.sheets;
    if (sheets.isEmpty) return null;

    ex.Sheet? best;
    int bestScore = -1;

    for (final entry in sheets.entries) {
      final sheet = entry.value;
      if (sheet.rows.isEmpty) continue;

      final headerRowIdx = _findHeaderRowIndexInSheet(sheet);
      final headerRow = sheet.rows[headerRowIdx];
      final header = headerRow.map((c) => _cellString(c?.value)).toList();
      final normalized = header.map(_normalizeHeader).toList();

      bool hasAny(List<String> aliases) {
        final set = aliases.map(_normalizeHeader).toSet();
        return normalized.any(set.contains);
      }

      final hasPlate = hasAny(['immat', 'immatriculation', 'plaque']);
      final hasBrand = hasAny(['marque']);
      final hasModel = hasAny(['modele', 'model', 'modèle']);
      final hasEntry = hasAny(['entree', 'entrée', "date d entree", "date d'entrée", 'date entree', 'date entrée']);
      final hasOps = hasAny(['aos', 'photo', 'photos', 'proov', 'proovstation', 'equipment', 'equipement', 'carcheck', 'aviloo', 'rvo']);

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

      if (score == 5) return sheet;
    }

    return best;
  }

  // ===== XLSX parsing (tolérant) =====
  List<Map<String, dynamic>> _parseXlsx(List<int> bytes, String kpiDate) {
    final excel = ex.Excel.decodeBytes(bytes);

    final sheet = _pickKpiSheet(excel);
    if (sheet == null || sheet.rows.isEmpty) return [];

    final headerRowIdx = _findHeaderRowIndexInSheet(sheet);
    final headerRow = sheet.rows[headerRowIdx];
    final header = headerRow.map((c) => _cellString(c?.value)).toList();

    // ✅ Plaque + Marque + Modèle : essentiels (mais alias très larges)
    final iPlate = _findHeaderIndex(header, ['Immat', 'Immatriculation', 'Plaque', 'Plate']);
    final iBrand = _findHeaderIndex(header, ['Marque', 'MARQUE', 'Brand'], required: false);
    final iModel = _findHeaderIndex(header, ['Modele', 'Modèle', 'Model'], required: false);

    // ✅ Tout le reste optionnel (moins strict)
    final iSite = _findHeaderIndex(
      header,
      ['Site', 'Site entree', 'Site d entree', 'Lieu', 'Emplacement', 'Location'],
      required: false,
    );

    final iEntry = _findHeaderIndex(
      header,
      [
        'Entrée',
        'Entree',
        "Date d'entrée",
        "Date d entree",
        'Date entrée',
        'Date entree',
        'Entrée sur site',
        'Entree sur site',
        'Date entree site',
        'Date entrée site',
      ],
      required: false,
    );

    final iAmPm = _findHeaderIndex(header, ['AM/PM', 'AM PM', 'AMPM'], required: false);

    final iForecast = _findHeaderIndex(
      header,
      ['Forecast Ventes', 'Forecast', 'Ventes', 'Catégorie ventes', 'Categorie ventes', 'Categorie', 'Catégorie'],
      required: false,
    );

    final iPhoto = _findHeaderIndex(header, ['AOS', 'Photos', 'Photo', 'Photocom', 'Photo commercial'], required: false);
    final iDamage = _findHeaderIndex(header, ['Proovstation', 'Proov', 'Dégâts', 'Degats', 'Dommages', 'Damage'], required: false);
    final iEquip = _findHeaderIndex(header, ['Equipment', 'Equipement', 'Équipement', 'Equip', 'Equipment check'], required: false);
    final iCar = _findHeaderIndex(header, ['CarCheck', 'Car Check', 'Carcheck'], required: false);

    final iAviloo = _findHeaderIndex(header, ['AVILOO', 'Aviloo'], required: false);

    final iRvoDamage = _findHeaderIndex(header, ['RVO Dégâts', 'RVO Degats', 'RVO dégâts', 'RVO degats', 'RVO dommages'], required: false);
    final iRvoEquip = _findHeaderIndex(header, ['RVO Equpmt', 'RVO Equipment', 'RVO Equipement', 'RVO equip'], required: false);

    final out = <Map<String, dynamic>>[];

    for (var r = headerRowIdx + 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      if (row.isEmpty) continue;

      final plateRaw = _cellString(_cellAt(row, iPlate)?.value);
      if (plateRaw.isEmpty) continue;

      final brand = iBrand >= 0 ? _cellString(_cellAt(row, iBrand)?.value) : '';
      final model = iModel >= 0 ? _cellString(_cellAt(row, iModel)?.value) : '';
      final site = iSite >= 0 ? _cellString(_cellAt(row, iSite)?.value) : '';
      final ampm = iAmPm >= 0 ? _cellString(_cellAt(row, iAmPm)?.value) : '';
      final forecast = iForecast >= 0 ? _cellString(_cellAt(row, iForecast)?.value) : '';

      final entryIso = iEntry >= 0 ? _toIsoDateDynamic(_cellAt(row, iEntry)?.value) : null;

      final opPhoto = iPhoto >= 0 ? _parseOp(_cellAt(row, iPhoto)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opCar = iCar >= 0 ? _parseOp(_cellAt(row, iCar)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opAviloo = iAviloo >= 0 ? _parseOp(_cellAt(row, iAviloo)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);

      final opDamageNormal = iDamage >= 0 ? _parseOp(_cellAt(row, iDamage)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opEquipNormal = iEquip >= 0 ? _parseOp(_cellAt(row, iEquip)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);

      final opDamageRvo = iRvoDamage >= 0 ? _parseOp(_cellAt(row, iRvoDamage)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opEquipRvo = iRvoEquip >= 0 ? _parseOp(_cellAt(row, iRvoEquip)?.value) : const _Op(required: false, doneIso: null, hasSomething: false);

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

  // ===== CSV parsing (tolérant) =====
  List<Map<String, dynamic>> _parseCsv(List<int> bytes, String kpiDate) {
    final text = utf8.decode(bytes);
    final rows = const CsvToListConverter().convert(text, eol: '\n');
    if (rows.isEmpty) return [];

    // détecte header dans les premières lignes
    int headerRowIdx = 0;
    int bestScore = -1;
    final scan = rows.length < 15 ? rows.length : 15;

    for (var r = 0; r < scan; r++) {
      final header = rows[r].map((e) => e.toString().trim()).toList();
      final normalized = header.map(_normalizeHeader).toList();

      bool hasAny(List<String> aliases) {
        final set = aliases.map(_normalizeHeader).toSet();
        return normalized.any(set.contains);
      }

      final hasPlate = hasAny(['immat', 'immatriculation', 'plaque', 'plate']);
      final hasBrand = hasAny(['marque', 'brand']);
      final hasModel = hasAny(['modele', 'model', 'modèle']);
      final hasEntry = hasAny(['entree', 'entrée', "date d entree", "date d'entrée", 'date entree', 'date entrée']);
      final hasOps = hasAny(['aos', 'photo', 'photos', 'proov', 'proovstation', 'equipment', 'equipement', 'carcheck', 'aviloo', 'rvo']);

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

      if (score >= 4) break;
    }

    final header = rows[headerRowIdx].map((e) => e.toString().trim()).toList();

    final iPlate = _findHeaderIndex(header, ['Immat', 'Immatriculation', 'Plaque', 'Plate']);
    final iBrand = _findHeaderIndex(header, ['Marque', 'MARQUE', 'Brand'], required: false);
    final iModel = _findHeaderIndex(header, ['Modele', 'Modèle', 'Model'], required: false);

    final iSite = _findHeaderIndex(
      header,
      ['Site', 'Site entree', 'Site d entree', 'Lieu', 'Emplacement', 'Location'],
      required: false,
    );

    final iEntry = _findHeaderIndex(
      header,
      [
        'Entrée',
        'Entree',
        "Date d'entrée",
        "Date d entree",
        'Date entrée',
        'Date entree',
        'Entrée sur site',
        'Entree sur site',
        'Date entree site',
        'Date entrée site',
      ],
      required: false,
    );

    final iAmPm = _findHeaderIndex(header, ['AM/PM', 'AM PM', 'AMPM'], required: false);

    final iForecast = _findHeaderIndex(
      header,
      ['Forecast Ventes', 'Forecast', 'Ventes', 'Catégorie ventes', 'Categorie ventes', 'Categorie', 'Catégorie'],
      required: false,
    );

    final iPhoto = _findHeaderIndex(header, ['AOS', 'Photos', 'Photo', 'Photocom', 'Photo commercial'], required: false);
    final iDamage = _findHeaderIndex(header, ['Proovstation', 'Proov', 'Dégâts', 'Degats', 'Dommages', 'Damage'], required: false);
    final iEquip = _findHeaderIndex(header, ['Equipment', 'Equipement', 'Équipement', 'Equip', 'Equipment check'], required: false);
    final iCar = _findHeaderIndex(header, ['CarCheck', 'Car Check', 'Carcheck'], required: false);

    final iAviloo = _findHeaderIndex(header, ['AVILOO', 'Aviloo'], required: false);

    final iRvoDamage = _findHeaderIndex(header, ['RVO Dégâts', 'RVO Degats', 'RVO dégâts', 'RVO degats', 'RVO dommages'], required: false);
    final iRvoEquip = _findHeaderIndex(header, ['RVO Equpmt', 'RVO Equipment', 'RVO Equipement', 'RVO equip'], required: false);

    final out = <Map<String, dynamic>>[];

    for (var r = headerRowIdx + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= iPlate) continue;

      final plateRaw = _cellString(_cellAt(row, iPlate));
      if (plateRaw.isEmpty) continue;

      final brand = iBrand >= 0 ? _cellString(_cellAt(row, iBrand)) : '';
      final model = iModel >= 0 ? _cellString(_cellAt(row, iModel)) : '';
      final site = iSite >= 0 ? _cellString(_cellAt(row, iSite)) : '';
      final ampm = iAmPm >= 0 ? _cellString(_cellAt(row, iAmPm)) : '';
      final forecast = iForecast >= 0 ? _cellString(_cellAt(row, iForecast)) : '';

      final entryIso = iEntry >= 0 ? _toIsoDateDynamic(_cellAt(row, iEntry)) : null;

      final opPhoto = iPhoto >= 0 ? _parseOp(_cellAt(row, iPhoto)) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opCar = iCar >= 0 ? _parseOp(_cellAt(row, iCar)) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opAviloo = iAviloo >= 0 ? _parseOp(_cellAt(row, iAviloo)) : const _Op(required: false, doneIso: null, hasSomething: false);

      final opDamageNormal = iDamage >= 0 ? _parseOp(_cellAt(row, iDamage)) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opEquipNormal = iEquip >= 0 ? _parseOp(_cellAt(row, iEquip)) : const _Op(required: false, doneIso: null, hasSomething: false);

      final opDamageRvo = iRvoDamage >= 0 ? _parseOp(_cellAt(row, iRvoDamage)) : const _Op(required: false, doneIso: null, hasSomething: false);
      final opEquipRvo = iRvoEquip >= 0 ? _parseOp(_cellAt(row, iRvoEquip)) : const _Op(required: false, doneIso: null, hasSomething: false);

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
                            style: const TextStyle(
                              color: Colors.black, // ✅ texte saisi noir
                            ),
                            cursorColor: Colors.black, // ✅ curseur noir
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              labelText: "Date KPI (yyyy-MM-dd)",
                              labelStyle: TextStyle(
                                color: Colors.black, // ✅ label noir
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
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
