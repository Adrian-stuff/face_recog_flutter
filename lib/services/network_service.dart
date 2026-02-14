import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

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
      return await _networkInfo.getWifiName();
    } catch (e) {
      debugPrint('Failed to get Wifi Name: $e');
      return null;
    }
  }

  /// Clean SSID by removing optional surrounding quotes
  String cleanSSID(String ssid) {
    if (ssid.startsWith('"') && ssid.endsWith('"')) {
      return ssid.substring(1, ssid.length - 1);
    }
    return ssid;
  }
}
