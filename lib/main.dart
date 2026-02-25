import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'state/app_state.dart';

import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'pages/validation_kpi_page.dart';
import 'pages/historique_page.dart';
import 'pages/settings_page.dart';
import 'pages/mode_selection_page.dart';
import 'pages/display_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ URL propres sur le web : /display au lieu de /#/display
  usePathUrlStrategy();

  await Supabase.initialize(
    url: 'https://vmgnsvunikuqctqajxbs.supabase.co',
    anonKey: 'sb_publishable_wKqmSOt3WGsiK7NS6d9TRQ_k7YsD6Lg',
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const KpiApp(),
    ),
  );
}

class KpiApp extends StatelessWidget {
  const KpiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KPI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFFB00020),
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFB00020),
          secondary: Color(0xFFB00020),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFB00020),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 55),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),

      // ✅ Ton flow normal reste pareil
      initialRoute: '/mode',

      routes: {
        '/': (context) => const LoginPage(),
        '/mode': (context) => const ModeSelectionPage(),
        '/display': (context) => const DisplayPage(),
        '/home': (context) => const HomePage(),
        '/validation': (context) => const ValidationKpiPage(),
        '/historique': (context) => const HistoriquePage(),
        '/settings': (context) => const SettingsPage(),
      },
    );
  }
}