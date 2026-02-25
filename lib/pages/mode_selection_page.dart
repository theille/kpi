import 'package:flutter/material.dart';
import '../state/site_prefs.dart';

class ModeSelectionPage extends StatefulWidget {
  const ModeSelectionPage({super.key});

  @override
  State<ModeSelectionPage> createState() => _ModeSelectionPageState();
}

class _ModeSelectionPageState extends State<ModeSelectionPage> {
  // ===== THEME COMMUN =====
  static const _bg = Color(0xFFF6F7FB);
  static const _card = Colors.white;
  static const _border = Color(0xFFE5E7EB);
  static const _text = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);
  static const _accent = Color(0xFF2563EB);

  // Pour l’instant on met Bouchain, tu pourras ajouter d’autres sites plus tard
  final List<String> _sites = const ['Bouchain'];
  String _selectedSite = 'Bouchain';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSite();
  }

  Future<void> _loadSite() async {
    final site = await SitePrefs.getSite();
    setState(() {
      _selectedSite = site;
      _loading = false;
    });
  }

  Widget buildModeCard(
      BuildContext context,
      String label,
      IconData icon,
      String route,
      ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InkWell(
        onTap: _loading
            ? null
            : () async {
          await SitePrefs.setSite(_selectedSite);
          if (!context.mounted) return;

          // ✅ Mode opérateur : on garde la page dans la pile pour pouvoir revenir en arrière si l'auth est annulée.
          if (route == '/') {
            Navigator.pushNamed(
              context,
              route,
              arguments: const {'requireOperatorAuth': true},
            );
          } else {
            Navigator.pushReplacementNamed(context, route);
          }
        },
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(18),
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
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: _accent, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _muted, size: 28),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 40),
              const Text('KPI',
                  style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      color: _text)),
              const SizedBox(height: 8),
              const Text('Sélection du mode',
                  style: TextStyle(
                      color: _muted, fontWeight: FontWeight.w700)),
              const SizedBox(height: 28),

              // ✅ Sélection du site
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on_rounded, color: _accent),
                    const SizedBox(width: 10),
                    const Text("Site",
                        style: TextStyle(
                            color: _text, fontWeight: FontWeight.w900)),
                    const Spacer(),
                    if (_loading)
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedSite,
                          items: _sites
                              .map((s) =>
                              DropdownMenuItem(value: s, child: Text(s)))
                              .toList(),
                          onChanged: (v) async {
                            if (v == null) return;
                            setState(() => _selectedSite = v);
                            await SitePrefs.setSite(v);
                          },
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 30),

              buildModeCard(context, 'Mode opérateur', Icons.person_rounded, '/'),
              buildModeCard(context, 'Mode afficheur', Icons.tv_rounded, '/display'),

              const Spacer(),
              const Text('KPI System',
                  style: TextStyle(
                      color: _muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}