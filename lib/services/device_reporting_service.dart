import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'local_database_service.dart';
import 'provisioning_service.dart';

/// Reports mobile app errors and sync health to the web dashboard so admins
/// can see kiosk problems (crashes, stuck syncs) without physically checking
/// each device.
///
/// Error reports are written to the local database before any network
/// attempt (see [reportError]), so a crash that happens while offline is
/// still on the device to send once connectivity returns, instead of being
/// lost the moment it happens. Sync-status heartbeats are not queued the
/// same way — they're a live snapshot of the current pending/failed counts,
/// and replaying a stale one later would just misreport what's true now.
///
/// Every network call here is best-effort: reporting must never throw,
/// block, or slow down the caller, since this is invoked from error handlers
/// and background sync loops that must keep running regardless of whether
/// the report itself succeeds.
class DeviceReportingService {
  DeviceReportingService._({http.Client? client, LocalDatabaseService? localDb})
    : _client = client ?? http.Client(),
      _localDb = localDb ?? LocalDatabaseService();
  static final DeviceReportingService instance = DeviceReportingService._();

  /// Test-only constructor for injecting a fake [http.Client] and/or
  /// [SharedPreferences] values without touching the real singleton.
  @visibleForTesting
  factory DeviceReportingService.forTesting({
    required http.Client client,
    LocalDatabaseService? localDb,
  }) => DeviceReportingService._(client: client, localDb: localDb);

  static const _deviceIdPrefKey = 'device_reporting_device_id';
  static const _requestTimeout = Duration(seconds: 8);

  final http.Client _client;
  final LocalDatabaseService _localDb;

  // Self-generated identity, used only for devices with no paired kiosk
  // record at all — a legacy build-time key with no per-device row behind
  // it (resolveKioskCompany's deviceId is null for that path server-side).
  String? _fallbackDeviceId;
  String? _fallbackDeviceLabel;
  String? _appVersion;
  bool _identityLoaded = false;

  /// The identity this device reports itself as — evaluated fresh on every
  /// call rather than cached, so a device that reports an error *before*
  /// pairing and then pairs later in the same session immediately switches
  /// over, rather than being stuck under the fallback identity until a
  /// restart.
  ///
  /// Prefers the real paired kiosk_devices.id/label
  /// (ProvisioningService.instance) once one exists, so a device showing up
  /// in the dashboard's Mobile App Health list is the same row an admin
  /// sees in Kiosk Configuration — not two disconnected identities for the
  /// same physical phone. Falls back to a self-generated id for devices
  /// with no per-device record (see above).
  String? get deviceId {
    final paired = ProvisioningService.instance.deviceId;
    if (paired != null) return paired.toString();
    return _fallbackDeviceId;
  }

  String? get deviceLabel {
    final paired = ProvisioningService.instance.deviceLabel;
    if (paired != null && paired.isNotEmpty) return paired;
    return _fallbackDeviceLabel;
  }

  String? get appVersion => _appVersion;

  /// Loads the device identity if it hasn't been already. Safe to call
  /// repeatedly; the work happens once.
  Future<void> ensureIdentity() => _ensureIdentity();

  Future<void> _ensureIdentity() async {
    if (_identityLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_deviceIdPrefKey);
      if (id == null) {
        id = _generateId();
        await prefs.setString(_deviceIdPrefKey, id);
      }
      _fallbackDeviceId = id;
      _fallbackDeviceLabel = '${Platform.operatingSystem}-${id.substring(0, 6)}';

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

  /// Sends one report, throwing unless the server actually accepted it.
  ///
  /// Both callers treat "returned without throwing" as proof of delivery and
  /// then mark the queued row uploaded, so anything that returns quietly here
  /// destroys the report. Two paths used to do exactly that:
  ///
  ///   * package:http only throws on transport failures — a 401, 403, 429 or
  ///     500 comes back as an ordinary Response. Every rejected report was
  ///     therefore recorded as delivered and dropped. That is not theoretical:
  ///     when the shared kiosk API key was retired, every kiosk endpoint
  ///     started answering 401, and reportError()'s immediate send runs with
  ///     no reachability gate in front of it — so the crash reports from
  ///     precisely that window were the ones being thrown away.
  ///   * a missing device identity returned early, silently.
  ///
  /// Throwing instead leaves the row queued for [syncPendingErrorReports],
  /// which is the only thing that actually guarantees delivery.
  Future<void> _post(String path, Map<String, dynamic> body) async {
    await _ensureIdentity();
    final id = deviceId;
    if (id == null) {
      throw StateError('Device identity unavailable; cannot attribute report');
    }

    final response = await _client
        .post(
          Uri.parse('${AppConfig.nextJsBaseUrl}$path'),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': ProvisioningService.instance.apiKey,
          },
          body: jsonEncode({
            'deviceId': id,
            'deviceLabel': deviceLabel,
            'appVersion': _appVersion,
            ...body,
          }),
        )
        .timeout(_requestTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Report rejected: HTTP ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Reports a single error/warning event. Failures are swallowed so a
  /// broken reporting call never masks or replaces the original error.
  ///
  /// Always written to the local queue first — if the device is offline
  /// right now (a very plausible time for a crash to happen), the report
  /// would otherwise simply be lost. The immediate upload attempt below is
  /// just a fast path for the common online case; [syncPendingErrorReports]
  /// is what actually guarantees delivery.
  Future<void> reportError(
    String message, {
    String level = 'error',
    String? context,
  }) async {
    await ensureIdentity(); // so the locally-queued row has an app version too

    int? localId;
    try {
      localId = await _localDb.insertErrorReport(
        level: level,
        message: message,
        context: context,
        appVersion: _appVersion,
      );
    } catch (e) {
      debugPrint('DeviceReportingService: failed to queue error report locally: $e');
    }

    try {
      await _post('/api/mobile/error-log', {
        'level': level,
        'message': message,
        'context': context,
      });
      if (localId != null) {
        await _localDb.markErrorReportsUploaded([localId]);
      }
    } catch (e) {
      debugPrint(
        'DeviceReportingService: immediate error report failed, left queued for retry: $e',
      );
    }
  }

  /// Uploads error reports that are still queued locally — either the
  /// device was offline when [reportError] ran, or the immediate attempt
  /// there failed. Called from the same background sync loop that drives
  /// attendance log and scan event sync.
  Future<void> syncPendingErrorReports() async {
    List<Map<String, dynamic>> pending;
    try {
      pending = await _localDb.getPendingErrorReports();
    } catch (e) {
      debugPrint('DeviceReportingService: failed to read pending error reports: $e');
      return;
    }
    if (pending.isEmpty) return;

    // Counted before the attempt, not after a failure, so a request that
    // dies mid-flight still advances the counter and can't be retried
    // forever at full rate — same convention as scan event sync.
    await _localDb.incrementErrorReportUploadAttempts(
      pending.map((r) => r['id'] as int).toList(),
    );

    final uploaded = <int>[];
    for (final report in pending) {
      try {
        await _post('/api/mobile/error-log', {
          'level': report['level'],
          'message': report['message'],
          'context': report['context'],
        });
        uploaded.add(report['id'] as int);
      } catch (e) {
        debugPrint(
          'DeviceReportingService: failed to sync queued error report ${report['id']}: $e',
        );
      }
    }
    if (uploaded.isNotEmpty) {
      await _localDb.markErrorReportsUploaded(uploaded);
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
