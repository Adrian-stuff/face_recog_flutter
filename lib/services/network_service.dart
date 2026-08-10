import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'dart:io';

/// Why a nearby-network scan couldn't be completed, so the UI can show a
/// message that actually tells the admin what to do next.
enum WifiScanFailure {
  /// Platform doesn't support listing nearby networks (e.g. iOS — Apple
  /// doesn't allow third-party apps to do this).
  notSupported,

  /// Location permission/service is required and wasn't granted/enabled.
  permissionOrLocationRequired,
}

class WifiScanException implements Exception {
  final WifiScanFailure reason;
  WifiScanException(this.reason);
}

/// One deduplicated nearby network from a scan, with the BSSID of whichever
/// access point broadcasting that SSID had the strongest signal — needed
/// because [NetworkService.getCurrentBSSID] only knows the BSSID of the
/// network the phone happens to be connected to right now, not of a network
/// an admin might pick from the list without connecting to it first.
class WifiNetworkResult {
  final String ssid;
  final String bssid;
  final int level;

  WifiNetworkResult({required this.ssid, required this.bssid, required this.level});
}

class GeoReading {
  final double latitude;
  final double longitude;
  // ponytail: reliable only on Android (real GPS-spoofing apps set this);
  // iOS has no equivalent flag, so isMocked is always false there.
  final bool isMocked;

  GeoReading({
    required this.latitude,
    required this.longitude,
    required this.isMocked,
  });
}

class NetworkService {
  final Connectivity _connectivity = Connectivity();
  final NetworkInfo _networkInfo = NetworkInfo();

  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;

  Future<String?> getCurrentSSID() async {
    // Request location permission on Android (needed for SSID)
    if (Platform.isAndroid) {
      var status = await Permission.location.status;
      if (!status.isGranted) {
        status = await Permission.location.request();
        if (!status.isGranted) {
          return null;
        }
      }
    }
    // Request location permission on iOS (needed for SSID)
    if (Platform.isIOS) {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        status = await Permission.locationWhenInUse.request();
        if (!status.isGranted) {
          return null;
        }
      }
    }

    try {
      final name = await _networkInfo.getWifiName();
      // Android wraps SSIDs in double-quotes (e.g. "\"MyNetwork\""); strip
      // them so callers always see the bare name — matching what wifi_scan
      // returns from scan results.
      return name == null ? null : cleanSSID(name);
    } catch (e) {
      debugPrint('Failed to get Wifi Name: $e');
      return null;
    }
  }

  /// Returns the access point's hardware address (e.g. "aa:bb:cc:dd:ee:ff").
  /// SSIDs are trivially spoofed by a rogue AP broadcasting the same name;
  /// the BSSID identifies the actual router.
  // ponytail: iOS rarely returns a real value here without a special Apple
  // "Access WiFi Information" entitlement, so treat a null BSSID as "unknown"
  // rather than a hard failure — see NetworkGuard for how that's handled.
  Future<String?> getCurrentBSSID() async {
    try {
      final bssid = await _networkInfo.getWifiBSSID();
      return bssid == null ? null : cleanSSID(bssid);
    } catch (e) {
      debugPrint('Failed to get Wifi BSSID: $e');
      return null;
    }
  }

  /// Scans for nearby WiFi network names, strongest signal first, so an
  /// admin can pick one instead of typing it by hand.
  ///
  /// Android only — iOS doesn't let third-party apps list nearby access
  /// points. Throws [WifiScanException] if scanning isn't available.
  Future<List<String>> scanNearbyNetworkNames() async {
    final results = await _scanRawResults();
    final seen = <String>{};
    final names = <String>[];
    for (final ap in results) {
      if (ap.ssid.isEmpty || !seen.add(ap.ssid)) continue;
      names.add(ap.ssid);
    }
    return names;
  }

  /// Like [scanNearbyNetworkNames], but keeps each network's BSSID — for
  /// NetworkSetupScreen, which reports whichever network the admin picks
  /// (not necessarily the one currently connected) to the dashboard.
  Future<List<WifiNetworkResult>> scanNearbyNetworks() async {
    final results = await _scanRawResults();
    final seen = <String>{};
    final networks = <WifiNetworkResult>[];
    for (final ap in results) {
      if (ap.ssid.isEmpty || !seen.add(ap.ssid)) continue;
      networks.add(WifiNetworkResult(ssid: ap.ssid, bssid: ap.bssid, level: ap.level));
    }
    return networks;
  }

  Future<List<WiFiAccessPoint>> _scanRawResults() async {
    final canStart = await WiFiScan.instance.canStartScan();
    if (canStart == CanStartScan.notSupported) {
      throw WifiScanException(WifiScanFailure.notSupported);
    }
    if (canStart != CanStartScan.yes) {
      throw WifiScanException(WifiScanFailure.permissionOrLocationRequired);
    }

    await WiFiScan.instance.startScan();
    // The platform scan runs asynchronously in the background; give it a
    // moment before reading results, or we'd just get stale/empty results.
    await Future.delayed(const Duration(seconds: 2));

    final canGet = await WiFiScan.instance.canGetScannedResults();
    if (canGet == CanGetScannedResults.notSupported) {
      throw WifiScanException(WifiScanFailure.notSupported);
    }
    if (canGet != CanGetScannedResults.yes) {
      throw WifiScanException(WifiScanFailure.permissionOrLocationRequired);
    }

    final results = await WiFiScan.instance.getScannedResults();
    results.sort((a, b) => b.level.compareTo(a.level));
    return results;
  }

  /// Clean SSID/BSSID by removing optional surrounding quotes
  String cleanSSID(String ssid) {
    if (ssid.startsWith('"') && ssid.endsWith('"')) {
      return ssid.substring(1, ssid.length - 1);
    }
    return ssid;
  }

  /// Current device GPS reading, or null if location is unavailable/denied.
  Future<GeoReading?> getCurrentGeoReading() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      final position = await Geolocator.getCurrentPosition();
      return GeoReading(
        latitude: position.latitude,
        longitude: position.longitude,
        isMocked: position.isMocked,
      );
    } catch (e) {
      debugPrint('Failed to get position: $e');
      return null;
    }
  }

  /// Distance in meters between two coordinates.
  double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }
}
