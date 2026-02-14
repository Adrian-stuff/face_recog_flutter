import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class SettingsService {
  static const String _keyWifiSSID = 'target_wifi_ssid';

  // Singleton
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  /// Save the target WiFi SSID
  Future<void> setWifiSSID(String ssid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWifiSSID, ssid);
  }

  /// Get the target WiFi SSID (defaults to AppConfig if not set)
  Future<String> getWifiSSID() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyWifiSSID) ??
        AppConfig.officeWifiSSID; // Use default from constant
  }

  /// Reset to default
  Future<void> resetWifiSSID() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyWifiSSID);
  }
}
