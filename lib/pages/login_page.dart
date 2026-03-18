import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../state/app_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final supabase = Supabase.instance.client;

  bool _checkedRouteArgs = false;
  bool _requireOperatorAuth = false;
  bool _operatorAuthed = false;

  // ✅ nouveau
  String _nextRoute = '/home';
  bool _forceAllTasks = false;

  bool damageSelected = false;
  bool carcheckSelected = false;
  bool photoSelected = false;
  bool equipmentSelected = false;
  bool avilooSelected = false;

  // ===== THEME COMMUN =====
  static const _bg = Color(0xFFF6F7FB);
  static const _card = Colors.white;
  static const _card2 = Color(0xFFF2F4F8);
  static const _border = Color(0xFFE5E7EB);
  static const _text = Color(0xFF0F172A);
  static const _muted = Color(0xFF64748B);
  static const _accent = Color(0xFF2563EB);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_checkedRouteArgs) return;
    _checkedRouteArgs = true;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final v = args['requireOperatorAuth'];
      _requireOperatorAuth = v == true;

      final routeArg = args['nextRoute'];
      if (routeArg is String && routeArg.isNotEmpty) {
        _nextRoute = routeArg;
      }

      final forceArg = args['forceAllTasks'];
      _forceAllTasks = forceArg == true;
    }

    // ✅ si on arrive en mode afficheur, on pré-active toutes les tâches visuellement
    if (_forceAllTasks) {
      damageSelected = true;
      carcheckSelected = true;
      photoSelected = true;
      equipmentSelected = true;
      avilooSelected = true;
    }

    // Si déjà connecté, on ne redemande pas
    if (supabase.auth.currentSession != null) {
      _operatorAuthed = true;
      return;
    }

    if (_requireOperatorAuth && !_operatorAuthed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showOperatorAuthDialog();
      });
    }
  }

  Future<void> _showOperatorAuthDialog() async {
    final idCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    final bool? success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        String? error;
        bool loading = false;

        return StatefulBuilder(
          builder: (context, setLocalState) {
            Future<void> validate() async {
              final identifiant = idCtrl.text.trim();
              final password = passCtrl.text;

              if (identifiant.isEmpty || password.isEmpty) {
                setLocalState(() {
                  error = "Veuillez remplir tous les champs.";
                });
                return;
              }

              setLocalState(() {
                loading = true;
                error = null;
              });

              try {
                final email = "$identifiant@kpi.local";

                await supabase.auth.signInWithPassword(
                  email: email,
                  password: password,
                );

                Navigator.of(dialogContext).pop(true);
              } on AuthException {
                setLocalState(() {
                  error = "Identifiant ou mot de passe incorrect.";
                });
              } catch (_) {
                setLocalState(() {
                  error = "Erreur serveur.";
                });
              } finally {
                setLocalState(() {
                  loading = false;
                });
              }
            }

            return AlertDialog(
              title: const Text("Accès opérateur"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: idCtrl,
                    decoration: const InputDecoration(labelText: "Identifiant"),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: "Mot de passe"),
                    onSubmitted: (_) => validate(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(false);
                  },
                  child: const Text("Annuler"),
                ),
                ElevatedButton(
                  onPressed: loading ? null : validate,
                  child: loading
                      ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Text("Valider"),
                ),
              ],
            );
          },
        );
      },
    );

    if (success != true) {
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  Widget buildTaskTile({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final Color tone = isSelected ? _accent : _muted;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isSelected ? _accent.withValues(alpha: 0.55) : _border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 14,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: tone),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: isSelected ? _accent : _card2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isSelected ? _accent : _border),
                ),
                child: Icon(
                  isSelected ? Icons.check_rounded : Icons.add_rounded,
                  color: isSelected ? Colors.white : _muted,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void goToHome() {
    if (_requireOperatorAuth && supabase.auth.currentSession == null) {
      _showOperatorAuthDialog();
      return;
    }

    final appState = Provider.of<AppState>(context, listen: false);

    if (_forceAllTasks) {
      appState.setTasks(
        damage: true,
        carcheck: true,
        photo: true,
        equipment: true,
        aviloo: true,
      );
    } else {
      appState.setTasks(
        damage: damageSelected,
        carcheck: carcheckSelected,
        photo: photoSelected,
        equipment: equipmentSelected,
        aviloo: avilooSelected,
      );
    }

    Navigator.pushReplacementNamed(context, _nextRoute);
  }

  int _selectedCount() {
    int c = 0;
    if (damageSelected) c++;
    if (carcheckSelected) c++;
    if (photoSelected) c++;
    if (equipmentSelected) c++;
    if (avilooSelected) c++;
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final count = _selectedCount();

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.assignment_rounded, color: _accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "KPI",
                            style: TextStyle(
                              color: _text,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _forceAllTasks
                                ? "Mode afficheur : toutes les tâches seront activées"
                                : "Sélectionne les tâches actives",
                            style: const TextStyle(
                              color: _muted,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: _card2,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: _border),
                      ),
                      child: Text(
                        "$count sélectionnée${count > 1 ? "s" : ""}",
                        style: const TextStyle(color: _muted, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              buildTaskTile(
                label: 'Relevé de dommages',
                icon: Icons.car_crash_rounded,
                isSelected: damageSelected,
                onTap: _forceAllTasks
                    ? () {}
                    : () => setState(() => damageSelected = !damageSelected),
              ),
              buildTaskTile(
                label: 'Carcheck',
                icon: Icons.fact_check_rounded,
                isSelected: carcheckSelected,
                onTap: _forceAllTasks
                    ? () {}
                    : () => setState(() => carcheckSelected = !carcheckSelected),
              ),
              buildTaskTile(
                label: 'Photo commercial',
                icon: Icons.photo_camera_rounded,
                isSelected: photoSelected,
                onTap: _forceAllTasks
                    ? () {}
                    : () => setState(() => photoSelected = !photoSelected),
              ),
              buildTaskTile(
                label: 'Relevé d’options',
                icon: Icons.build_circle_rounded,
                isSelected: equipmentSelected,
                onTap: _forceAllTasks
                    ? () {}
                    : () => setState(() => equipmentSelected = !equipmentSelected),
              ),
              buildTaskTile(
                label: 'Aviloo',
                icon: Icons.science_rounded,
                isSelected: avilooSelected,
                onTap: _forceAllTasks
                    ? () {}
                    : () => setState(() => avilooSelected = !avilooSelected),
              ),

              const SizedBox(height: 18),

              ElevatedButton(
                onPressed: goToHome,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
                child: Text(_forceAllTasks ? 'Accéder à l’afficheur' : 'Suivant'),
              ),

              const SizedBox(height: 10),

              Text(
                _forceAllTasks
                    ? "Toutes les tâches sont activées pour le mode afficheur."
                    : "Astuce : tu peux activer plusieurs tâches. Elles seront envoyées au serveur lors de chaque validation.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: _muted, fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
