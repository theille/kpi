import 'package:shared_preferences/shared_preferences.dart';

class SitePrefs {
  static const _kSite = 'selected_site';

  static Future<void> setSite(String site) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSite, site);
  }

  static Future<String> getSite() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSite) ?? 'Bouchain';
  }
}
