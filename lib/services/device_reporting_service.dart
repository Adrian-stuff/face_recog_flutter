import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

/// Reports mobile app errors and sync health to the web dashboard so admins
/// can see kiosk problems (crashes, stuck syncs) without physically checking
/// each device.
///
/// Every network call here is best-effort: reporting must never throw,
/// block, or slow down the caller, since this is invoked from error handlers
/// and background sync loops that must keep running regardless of whether
/// the report itself succeeds.
class DeviceReportingService {
  DeviceReportingService._({http.Client? client})
    : _client = client ?? http.Client();
  static final DeviceReportingService instance = DeviceReportingService._();

  /// Test-only constructor for injecting a fake [http.Client] and/or
  /// [SharedPreferences] values without touching the real singleton.
  @visibleForTesting
  factory DeviceReportingService.forTesting({required http.Client client}) =>
      DeviceReportingService._(client: client);

  static const _deviceIdPrefKey = 'device_reporting_device_id';
  static const _requestTimeout = Duration(seconds: 8);

  final http.Client _client;

  String? _deviceId;
  String? _deviceLabel;
  String? _appVersion;
  bool _identityLoaded = false;

  Future<void> _ensureIdentity() async {
    if (_identityLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_deviceIdPrefKey);
      if (id == null) {
        id = _generateId();
        await prefs.setString(_deviceIdPrefKey, id);
      }
      _deviceId = id;
      _deviceLabel = '${Platform.operatingSystem}-${id.substring(0, 6)}';

      try {
        final info = await PackageInfo.fromPlatform();
        _appVersion = '${info.version}+${info.buildNumber}';
      } catch (e) {
        debugPrint('DeviceReportingService: failed to read app version: $e');
      }
    } catch (e) {
      debugPrint('DeviceReportingService: failed to load device identity: $e');
    } finally {
      // Even on failure, mark as loaded so every call site doesn't retry the
      // (already failed) shared_preferences/package_info lookups forever.
      _identityLoaded = true;
    }
  }

  String _generateId() {
    final rand = Random.secure();
    return List.generate(16, (_) => rand.nextInt(16).toRadixString(16)).join();
  }

  Future<void> _post(String path, Map<String, dynamic> body) async {
    await _ensureIdentity();
    if (_deviceId == null) return; // identity load failed; nothing to tag the report with

    await _client
        .post(
          Uri.parse('${AppConfig.nextJsBaseUrl}$path'),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': AppConfig.mobileApiKey,
          },
          body: jsonEncode({
            'deviceId': _deviceId,
            'deviceLabel': _deviceLabel,
            'appVersion': _appVersion,
            ...body,
          }),
        )
        .timeout(_requestTimeout);
  }

  /// Reports a single error/warning event. Failures are swallowed so a
  /// broken reporting call never masks or replaces the original error.
  Future<void> reportError(
    String message, {
    String level = 'error',
    String? context,
  }) async {
    try {
      await _post('/api/mobile/error-log', {
        'level': level,
        'message': message,
        'context': context,
      });
    } catch (e) {
      debugPrint('DeviceReportingService: failed to report error: $e');
    }
  }

  /// Reports the current sync-health snapshot (pending/failed counts) so the
  /// dashboard has a live heartbeat per device, not just error events.
  Future<void> reportSyncStatus({
    required int pendingCount,
    required int failedCount,
  }) async {
    try {
      await _post('/api/mobile/sync-status', {
        'pendingCount': pendingCount,
        'failedCount': failedCount,
      });
    } catch (e) {
      debugPrint('DeviceReportingService: failed to report sync status: $e');
    }
  }
}
