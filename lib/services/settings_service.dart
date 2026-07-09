import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class GeofenceConfig {
  final double latitude;
  final double longitude;
  final double radiusMeters;

  GeofenceConfig({
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
  });
}

class SettingsService {
  static const String _keyWifiSSID = 'target_wifi_ssid';
  static const String _keyWifiBSSID = 'target_wifi_bssid';
  static const String _keyOfficeLat = 'office_lat';
  static const String _keyOfficeLng = 'office_lng';
  static const String _keyGeofenceRadius = 'geofence_radius_m';
  static const double defaultGeofenceRadiusMeters = 150;

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

  /// Save the target WiFi BSSID (empty string means "not enforced")
  Future<void> setWifiBSSID(String bssid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWifiBSSID, bssid);
  }

  /// Get the target WiFi BSSID. Empty string if never configured, which
  /// NetworkGuard treats as "BSSID check not enforced".
  Future<String> getWifiBSSID() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyWifiBSSID) ?? '';
  }

  /// Reset to unconfigured (BSSID check not enforced)
  Future<void> resetWifiBSSID() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyWifiBSSID);
  }

  /// Save the office coordinates and geofence radius
  Future<void> setGeofence(double latitude, double longitude, double radiusMeters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyOfficeLat, latitude);
    await prefs.setDouble(_keyOfficeLng, longitude);
    await prefs.setDouble(_keyGeofenceRadius, radiusMeters);
  }

  /// Get the configured geofence, or null if an admin hasn't set one yet
  /// (NetworkGuard treats a null geofence as "GPS check not enforced").
  Future<GeofenceConfig?> getGeofence() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_keyOfficeLat);
    final lng = prefs.getDouble(_keyOfficeLng);
    if (lat == null || lng == null) return null;
    return GeofenceConfig(
      latitude: lat,
      longitude: lng,
      radiusMeters:
          prefs.getDouble(_keyGeofenceRadius) ?? defaultGeofenceRadiusMeters,
    );
  }

  /// Clear the configured geofence (GPS check reverts to "not enforced")
  Future<void> resetGeofence() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyOfficeLat);
    await prefs.remove(_keyOfficeLng);
    await prefs.remove(_keyGeofenceRadius);
  }
}
