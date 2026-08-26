import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';
import 'local_database_service.dart';
import 'face_service.dart';
import 'device_reporting_service.dart';
import 'settings_service.dart';
import 'provisioning_service.dart';
import 'network_service.dart';

/// Snapshot of offline records still waiting to sync or that the server
/// permanently rejected (e.g. too old, or a genuine conflict).
class SyncStatus {
  final int pendingCount;
  final List<Map<String, dynamic>> failedLogs;
  final List<Map<String, dynamic>> failedEncodings;

  SyncStatus({
    required this.pendingCount,
    required this.failedLogs,
    required this.failedEncodings,
  });

  int get failedCount => failedLogs.length + failedEncodings.length;
  bool get hasIssues => pendingCount > 0 || failedCount > 0;
}

/// One specific punch's outcome, distinct from the aggregate [SyncStatus].
/// [pending] covers both "still offline" and "online but syncLogs() hasn't
/// resolved this row yet" — the caller isn't meant to tell those apart from
/// this alone, since it's polled with a bounded wait right after the punch.
enum PunchSyncState { pending, confirmed, rejected }

/// Distinguishes "no network radio at all" from "radio's up but the server
/// isn't reachable" (captive portal, VPN issue, server down) — the two
/// failure modes [SupabaseService.isOnline] and [SupabaseService.pingServer]
/// already detect separately, surfaced here so the UI can say which one is
/// actually happening instead of a single generic "offline".
enum ConnectivityStatus { online, noConnection, serverUnreachable }

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  final LocalDatabaseService _localDb = LocalDatabaseService();
  final NetworkService _networkService = NetworkService();
  static const Uuid _uuid = Uuid();
  Timer? _syncTimer;
  StreamSubscription<List<ConnectivityResult>>? _reconnectSyncSubscription;
  bool _wasOnline = true;
  bool _syncingLogs = false;
  bool _syncingEncodings = false;
  bool _syncingScanEvents = false;
  bool _syncingEmployees = false;

  static const int _scanBatchSize = 50;
  static const int _maxScanBackoffSeconds = 30 * 60;
  Duration _scanBackoff = Duration.zero;
  DateTime? _scanBackoffUntil;

  /// Reconciliation is a whole-queue check, so it runs on its own slower
  /// cadence rather than on every sync tick.
  DateTime? _lastReconcileAt;
  static const Duration _reconcileInterval = Duration(hours: 1);

  /// Same idea for the full employee roster download — worth checking often
  /// for logs/scan events, wasteful to re-fetch every tick.
  DateTime? _lastEmployeeSyncAt;
  static const Duration _employeeSyncInterval = Duration(minutes: 5);

  /// Name of the company this device's MOBILE_API_KEY is provisioned for
  /// (multi-tenant deployment — every device belongs to exactly one
  /// company). Populated by [pingServer]; null until the first successful
  /// ping. A ValueNotifier so screens can reactively show it without
  /// each one re-fetching it themselves.
  final ValueNotifier<String?> companyName = ValueNotifier<String?>(null);

  /// Same idea as [companyName]: lets screens reactively show a "can't
  /// reach the server" banner without each one running its own
  /// Connectivity()/pingServer() checks. Updated by [checkConnectivityStatus]
  /// and the reconnect listener in [startBackgroundSync] — not by every
  /// caller of [isOnline]/[pingServer] individually, since most of those
  /// (e.g. the per-sync-method early returns) run far too often to double as
  /// a UI-facing signal. Starts optimistic (`online`) so a cold app launch
  /// doesn't flash an offline banner before the first check has even run.
  final ValueNotifier<ConnectivityStatus> connectivityStatus =
      ValueNotifier<ConnectivityStatus>(ConnectivityStatus.online);

  /// Check internet connectivity
  Future<bool> get isOnline async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.any((r) => r != ConnectivityResult.none);
  }

  /// Radio-first, then real reachability: checking [isOnline] before
  /// [pingServer] avoids firing a request that's certain to time out when
  /// there's no radio at all, and keeps the two failure modes distinguishable
  /// in [connectivityStatus] instead of collapsing both into one boolean.
  Future<bool> checkConnectivityStatus() async {
    if (!await isOnline) {
      connectivityStatus.value = ConnectivityStatus.noConnection;
      return false;
    }
    final reachable = await pingServer();
    connectivityStatus.value = reachable
        ? ConnectivityStatus.online
        : ConnectivityStatus.serverUnreachable;
    return reachable;
  }

  /// Whether a specific punch (by the `clientEventId` [recordAttendance]
  /// returned for it) has actually reached the server, been rejected, or is
  /// still waiting — backs the punch-confirmation dialog's bounded wait so it
  /// doesn't just assume "saved locally" means "confirmed".
  Future<PunchSyncState> getPunchSyncState(String clientEventId) async {
    final row = await _localDb.getLogByClientEventId(clientEventId);
    if (row == null || (row['is_synced'] as int?) != 1) {
      return PunchSyncState.pending;
    }
    return row['sync_error'] == null
        ? PunchSyncState.confirmed
        : PunchSyncState.rejected;
  }

  // --- Synchronization ---

  /// Syncs employees from Supabase to Local DB (Down Sync)
  Future<void> syncEmployees() async {
    if (!await isOnline) return;

    // syncEmployees() is fired from many call sites (periodic timer,
    // reconnect handler, post-match refresh, registration) without always
    // being awaited, so overlapping invocations are routine rather than
    // rare. Each one runs a `db.transaction()` against the same local
    // table; without this guard two overlapping transactions on the local
    // db raced and sqflite occasionally failed to roll one of them back
    // ("Cannot perform this operation because there is no current
    // transaction. sql 'ROLLBACK'"). syncLogs/syncEncodings/syncScanEvents
    // already use this same guard for the same reason.
    if (_syncingEmployees) return;
    _syncingEmployees = true;

    try {
      // Use the optimized API endpoint to fetch employees with cached/limited encodings
      final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/sync/employees');
      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': ProvisioningService.instance.apiKey,
        },
      );

      if (response.statusCode != 200) {
        debugPrint('Sync Failed: ${response.statusCode} - ${response.body}');
        return;
      }

      final List<dynamic> employees = jsonDecode(response.body);

      final List<Map<String, dynamic>> localData = employees.map((e) {
        final features = e['face_features'];

        String? descriptorStr;
        if (features != null && features is List && features.isNotEmpty) {
          // New format: [{descriptor: [...], is_golden: bool}, ...]
          // We store the whole enriched list so the local cache knows which are golden.
          // Legacy format (plain list of arrays) is also handled in _initializeVectorCache.
          descriptorStr = jsonEncode(features);
        }

        return {
          'id': e['id'],
          'first_name': e['first_name'],
          'last_name': e['last_name'],
          'position': e['position'],
          'image_url': e['image_url'],
          'face_features': descriptorStr,
        };
      }).toList();

      await _localDb.syncEmployees(localData);

      for (var emp in employees) {
        final empId = emp['id'] as int;

        // The avatar endpoint, not the raw `image_url` column, is this
        // app's single source of truth for "what an employee currently
        // looks like": the endpoint resolves the *latest* photo from
        // storage (see app/dashboard/employees/api/avatar/route.ts), while
        // `image_url` is whatever was set once at enrollment and is never
        // updated by later re-registrations. Both used to be downloaded
        // here to the same local file — genuinely redundant, since they're
        // supposed to represent the same avatar, but not actually
        // equivalent, so an employee's cached photo could silently drift
        // to a stale enrollment image instead of their current one
        // whenever the (correct) avatar-endpoint download happened to fail
        // on a given sync while the (stale) image_url one succeeded and
        // overwrote the file that was already right.
        final avatarUrl = AppConfig.getEmployeeAvatarUrl(empId);
        await _downloadAndCacheEmployeeImage(empId, avatarUrl);
      }
    } catch (e) {
      debugPrint('Sync Error: $e');
      DeviceReportingService.instance.reportError(
        'Employee sync failed: $e',
        context: 'syncEmployees',
      );
    } finally {
      _syncingEmployees = false;
    }
  }

  /// Gets the avatar URL for an employee (with local caching fallback)
  Future<String?> getEmployeeAvatarUrl(
    int employeeId, {
    bool preferLocal = true,
  }) async {
    if (preferLocal) {
      // Check if local cached version exists
      final localPath = await _getLocalImagePath(employeeId);
      if (localPath != null && localPath.isNotEmpty) {
        final file = File(localPath);
        if (await file.exists()) {
          return localPath;
        }
      }
    }

    // Return the avatar API endpoint URL (will be loaded with network image)
    return AppConfig.getEmployeeAvatarUrl(employeeId);
  }

  /// Gets the local cached image path for an employee
  Future<String?> _getLocalImagePath(int employeeId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localPath = p.join(
        appDir.path,
        'employee_avatars',
        '${employeeId}_avatar.jpg',
      );
      return localPath;
    } catch (e) {
      debugPrint('Error getting local image path: $e');
      return null;
    }
  }

  Future<String?> _downloadAndCacheEmployeeImage(
    int employeeId,
    String imageUrl,
  ) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(p.join(appDir.path, 'employee_avatars'));

      if (!await imagesDir.exists()) {
        try {
          await imagesDir.create(recursive: true);
        } catch (e) {
          debugPrint('Failed to create avatars directory: $e');
          return null;
        }
      }

      final localPath = p.join(imagesDir.path, '${employeeId}_avatar.jpg');
      final localFile = File(localPath);

      // If file already exists and is recent, skip re-downloading. This
      // endpoint always resolves the current photo server-side (there's no
      // longer a second, staler source competing to overwrite it — see the
      // comment in syncEmployees()), so this window only needs to be short
      // enough that a newly-changed photo shows up on the next few sync
      // ticks rather than sitting wrong for the better part of a day.
      if (await localFile.exists()) {
        try {
          final stat = await localFile.stat();
          final age = DateTime.now().difference(stat.modified);
          if (age.inHours < 1) {
            await _localDb.updateEmployeeLocalImagePath(employeeId, localPath);
            debugPrint('Using cached avatar for employee $employeeId');
            return localPath;
          }
        } catch (e) {
          debugPrint('Error checking cache age: $e');
        }
      }

      // Download with proper timeout and error handling
      try {
        final response = await http
            .get(
              Uri.parse(imageUrl),
              headers: {'x-api-key': ProvisioningService.instance.apiKey},
            )
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => http.Response('Download timeout', 408),
            );

        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          // Write to temp file first, then move to avoid corruption
          final tempPath = '$localPath.tmp';
          final tempFile = File(tempPath);

          await tempFile.writeAsBytes(response.bodyBytes);

          // Atomic move
          await tempFile.rename(localPath);

          await _localDb.updateEmployeeLocalImagePath(employeeId, localPath);
          debugPrint(
            'Downloaded and cached avatar for employee $employeeId (${response.bodyBytes.length} bytes)',
          );
          return localPath;
        } else {
          debugPrint(
            'Failed to download avatar for $employeeId: HTTP ${response.statusCode}',
          );
        }
      } on TimeoutException {
        debugPrint(
          'Timeout downloading avatar for employee $employeeId from $imageUrl',
        );
      }
    } catch (e) {
      debugPrint('Error caching avatar for employee $employeeId: $e');
    }
    return null;
  }

  /// Syncs offline logs to Supabase (Up Sync)
  /// Pulls the "error" field out of a JSON error response, falling back to
  /// the raw body if it isn't the expected shape.
  String _extractErrorMessage(String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return responseBody;
  }

  /// Pushes the current sync-health snapshot to the dashboard so admins have
  /// a live per-device heartbeat, not just error events. Best-effort — see
  /// [DeviceReportingService].
  Future<void> _reportSyncHeartbeat() async {
    try {
      final status = await getSyncStatus();
      await DeviceReportingService.instance.reportSyncStatus(
        pendingCount: status.pendingCount,
        failedCount: status.failedCount,
      );
    } catch (e) {
      debugPrint('Failed to report sync heartbeat: $e');
    }
  }

  /// Counts of records still waiting to sync or that permanently failed —
  /// surfaced in the UI so an outage isn't invisible until logs start
  /// aging out of the server's sync window.
  Future<SyncStatus> getSyncStatus() async {
    final pendingLogs = await _localDb.getPendingLogsCount();
    final pendingEncodings = await _localDb.getPendingEncodingsCount();
    final failedLogs = await _localDb.getFailedLogs();
    final failedEncodings = await _localDb.getFailedEncodings();
    return SyncStatus(
      pendingCount: pendingLogs + pendingEncodings,
      failedLogs: failedLogs,
      failedEncodings: failedEncodings,
    );
  }

  /// Dismisses a single sync issue (log or encoding) without retrying it —
  /// e.g. a duplicate "Already timed in" rejection where the real record
  /// already made it to the server.
  Future<void> clearSyncIssue({int? logId, int? encodingId}) async {
    if (logId != null) await _localDb.clearFailedLog(logId);
    if (encodingId != null) await _localDb.clearFailedEncoding(encodingId);
  }

  Future<void> clearAllSyncIssues() async {
    await _localDb.clearFailedLogs();
    await _localDb.clearFailedEncodings();
  }

  /// Returns recent server-rejected scans since [since].
  Future<List<Map<String, dynamic>>> getRecentRejections(DateTime since) async {
    return await _localDb.getRecentRejections(since);
  }

  Future<void> syncLogs() async {
    // syncLogs() is triggered concurrently from the periodic timer, the
    // reconnect listener, and every recordAttendance() call. Without this
    // guard, two overlapping runs can both fetch and POST the same
    // unsynced row; the server's duplicate guard rejects the second POST,
    // and that (actually-synced) record gets mislabeled as permanently
    // failed. A second call while one is in flight just no-ops — the
    // periodic timer/reconnect listener will pick up anything left over.
    if (_syncingLogs) return;
    if (!await isOnline) return;

    _syncingLogs = true;
    try {
      final logs = await _localDb.getUnsyncedLogs();
      if (logs.isEmpty) return;

      for (var log in logs) {
        try {
          final timestamp = log['timestamp'] as String;
          final timeStr = timestamp.split('T')[1].substring(0, 8);

          final url = Uri.parse(
            '${AppConfig.nextJsBaseUrl}/api/attendance/log',
          );
          final response = await http.post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
            body: jsonEncode({
              'employeeId': log['employee_id'],
              'type': log['type'],
              'time': timeStr,
              'timestamp': timestamp,
              // Makes this POST safely repeatable: if we already sent it and
              // lost the response, the server returns the original record
              // instead of rejecting a "duplicate" we'd then file as failed.
              if (log['client_event_id'] != null)
                'clientEventId': log['client_event_id'],
              if (log['lat'] != null) 'lat': log['lat'],
              if (log['lng'] != null) 'lng': log['lng'],
              if (log['is_mocked'] != null) 'isMocked': log['is_mocked'] == 1,
              if (log['wifi_ssid'] != null) 'wifiSsid': log['wifi_ssid'],
              if (log['wifi_bssid'] != null) 'wifiBssid': log['wifi_bssid'],
              // The build that recorded this punch, read off the row rather
              // than from the running app — see insertOfflineLog. Rows queued
              // before this column existed send nothing and stay null.
              if (log['app_version'] != null) 'appVersion': log['app_version'],
            }),
          );

          final clientEventId = log['client_event_id'] as String?;

          if (response.statusCode >= 200 && response.statusCode < 300) {
            // Mark as synced only if successful
            await _localDb.markLogsAsSynced([log['id'] as int]);
            if (clientEventId != null) {
              await _localDb.updateScanOutcome(clientEventId, 'recorded');
              await _localDb.markScansServerConfirmed([clientEventId]);
            }
          } else if (response.statusCode >= 400 && response.statusCode < 500) {
            // Client error (e.g. 'Already timed in', or too old to sync).
            // Retrying won't fix it, but unlike a real success this must stay
            // visible — silently discarding it would mean this attendance
            // record is gone with no trace anywhere.
            final reason = _extractErrorMessage(response.body);
            debugPrint('Client error syncing log ${log['id']}: $reason');
            await _localDb.markLogsAsFailed([log['id'] as int], reason);
            if (clientEventId != null) {
              await _localDb.updateScanOutcome(
                clientEventId,
                'server_rejected',
                rejectionReason: reason,
              );
            }
          } else {
            debugPrint(
              'Failed to sync log ${log['id']} (Server error): ${response.body}',
            );
            DeviceReportingService.instance.reportError(
              'Server error syncing attendance log: HTTP ${response.statusCode}',
              context: 'syncLogs log=${log['id']} body=${response.body}',
            );
          }
        } catch (e) {
          debugPrint('Failed to sync log ${log['id']}: $e');
          DeviceReportingService.instance.reportError(
            'Failed to sync attendance log: $e',
            context: 'syncLogs log=${log['id']}',
          );
        }
      }
    } finally {
      _syncingLogs = false;
    }
  }

  /// Uploads the scan evidence trail in batches.
  ///
  /// Separate from [syncLogs] on purpose: a scan that produced no attendance
  /// record (no match, failed liveness, server rejection) has nothing to send
  /// through the attendance endpoint, and those are the ones most worth
  /// having when someone disputes a missing entry later.
  Future<void> syncScanEvents() async {
    if (_syncingScanEvents) return;
    if (!await isOnline) return;

    _syncingScanEvents = true;
    try {
      final pending = await _localDb.getPendingScanEvents(limit: _scanBatchSize);
      if (pending.isEmpty) return;

      // Every row must carry the device that produced it; without an identity
      // the evidence can't be attributed to a kiosk and the server rejects it.
      await DeviceReportingService.instance.ensureIdentity();
      if (DeviceReportingService.instance.deviceId == null) {
        debugPrint('Scan event upload skipped: no device identity');
        return;
      }

      final ids = pending
          .map((e) => e['client_event_id'] as String)
          .toList(growable: false);

      // Counted before the attempt, not after a failure, so a request that
      // dies mid-flight still advances the counter and can't be retried
      // forever at full rate.
      await _localDb.incrementScanUploadAttempts(ids);

      final payload = pending.map((e) {
        return {
          'clientEventId': e['client_event_id'],
          'deviceId': DeviceReportingService.instance.deviceId,
          'deviceLabel': DeviceReportingService.instance.deviceLabel,
          'scannedAt': e['scanned_at'],
          'outcome': e['outcome'],
          if (e['employee_id'] != null) 'employeeId': e['employee_id'],
          if (e['attendance_type'] != null) 'attendanceType': e['attendance_type'],
          if (e['match_confidence'] != null)
            'matchConfidence': e['match_confidence'],
          if (e['liveness_passed'] != null)
            'livenessPassed': e['liveness_passed'] == 1,
          if (e['thumbnail'] != null) 'thumbnail': e['thumbnail'],
          if (e['rejection_reason'] != null)
            'rejectionReason': e['rejection_reason'],
          if (e['lat'] != null) 'lat': e['lat'],
          if (e['lng'] != null) 'lng': e['lng'],
          if (e['wifi_ssid'] != null) 'wifiSsid': e['wifi_ssid'],
          if (e['wifi_bssid'] != null) 'wifiBssid': e['wifi_bssid'],
        };
      }).toList();

      final response = await http
          .post(
            Uri.parse('${AppConfig.nextJsBaseUrl}/api/mobile/scan-events'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
            body: jsonEncode({'events': payload}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final accepted = (body['accepted'] as List?)?.cast<String>() ?? const [];
        await _localDb.markScanEventsUploaded(accepted);

        // Rejected events stay pending and keep their attempt count, so the
        // cap in getPendingScanEvents eventually retires them rather than
        // letting one malformed row block the batch behind it.
        //
        // Retiring them is quiet, though, and that quiet has already cost us:
        // the kiosk shipped a `device_rejected` outcome the server did not yet
        // accept, every such scan was refused, retried ten times and dropped,
        // and the only trace was a debugPrint nobody reads off a wall-mounted
        // tablet. Evidence went missing for months with no signal anywhere.
        //
        // A rejection is a disagreement between two deployed versions, which
        // is a thing an operator has to be told about. Reporting it through
        // the error channel — which queues locally and survives being offline
        // — turns the next drift into something visible on day one.
        final rejected = (body['rejected'] as List?) ?? const [];
        if (rejected.isNotEmpty) {
          debugPrint('Scan event upload: ${rejected.length} rejected');
          final reasons = rejected
              .map((r) => (r as Map)['reason']?.toString() ?? 'unspecified')
              .toSet()
              .take(3)
              .join('; ');
          unawaited(
            DeviceReportingService.instance.reportError(
              'Server refused ${rejected.length} scan event(s) on upload. '
              'These will be retried and then dropped, losing the evidence. '
              'Reasons: $reasons',
              level: 'warning',
              context: 'scan_event_upload',
            ),
          );
        }
        _scanBackoff = Duration.zero;
      } else {
        _applyScanBackoff();
        debugPrint('Scan event upload failed: HTTP ${response.statusCode}');
      }
    } catch (e) {
      _applyScanBackoff();
      debugPrint('Scan event upload failed: $e');
    } finally {
      _syncingScanEvents = false;
    }
  }

  /// Asks the server which of the logs this device believes are synced it
  /// actually holds, and re-queues the ones it doesn't.
  ///
  /// This is the check that closes the loop: a device marks a log synced on a
  /// 2xx, but a response lost after the server committed — or an ack that
  /// never arrived — left the two silently disagreeing with no way to ever
  /// notice. Anything that comes back missing is a scan that really happened
  /// and was never recorded.
  Future<void> reconcileWithServer() async {
    if (!await isOnline) return;

    try {
      final ids = await _localDb.getSyncedClientEventIds(limit: 200);
      if (ids.isEmpty) return;

      final response = await http
          .post(
            Uri.parse('${AppConfig.nextJsBaseUrl}/api/mobile/reconcile'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
            body: jsonEncode({'clientEventIds': ids}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        debugPrint('Reconcile failed: HTTP ${response.statusCode}');
        return;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final recorded = (body['recorded'] as List?)?.cast<String>() ?? const [];
      final missing = (body['missing'] as List?)?.cast<String>() ?? const [];

      await _localDb.markScansServerConfirmed(recorded);

      if (missing.isNotEmpty) {
        final requeued = await _localDb.requeueLogsByClientEventIds(missing);
        debugPrint('Reconcile: $requeued log(s) missing server-side, re-queued');
        await DeviceReportingService.instance.reportError(
          'Reconciliation found $requeued attendance log(s) the server had no '
          'record of; re-queued for upload',
          level: 'warning',
          context: 'missing clientEventIds: ${missing.take(20).join(", ")}',
        );
        // Send them straight back up rather than waiting for the next tick.
        await syncLogs();
      }
    } catch (e) {
      debugPrint('Reconcile failed: $e');
    }
  }

  void _applyScanBackoff() {
    // Doubles up to a ceiling, so a server outage doesn't turn every device
    // into a retry loop hammering it once a tick.
    _scanBackoff = _scanBackoff == Duration.zero
        ? const Duration(minutes: 1)
        : Duration(
            seconds: (_scanBackoff.inSeconds * 2).clamp(60, _maxScanBackoffSeconds),
          );
    _scanBackoffUntil = DateTime.now().add(_scanBackoff);
  }

  bool get _scanBackoffActive =>
      _scanBackoffUntil != null && DateTime.now().isBefore(_scanBackoffUntil!);

  /// Syncs offline face encodings to Supabase (Up Sync)
  Future<void> syncEncodings() async {
    // Same overlapping-callers issue as syncLogs() — see the comment there.
    if (_syncingEncodings) return;
    if (!await isOnline) return;

    _syncingEncodings = true;
    try {
      final encodings = await _localDb.getUnsyncedEncodings();
      if (encodings.isEmpty) return;

      for (var enc in encodings) {
        try {
          final descriptorStr = enc['descriptor'] as String;
          final descriptor = jsonDecode(descriptorStr) as List<dynamic>;

          final url = Uri.parse(
            '${AppConfig.nextJsBaseUrl}/api/face-encoding',
          );
          final response = await http.post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
            body: jsonEncode({
              'employeeId': enc['employee_id'],
              'descriptor': descriptor,
              'isGolden': enc['is_golden'] == 1,
            }),
          );

          if (response.statusCode >= 200 && response.statusCode < 300) {
            await _localDb.markEncodingsAsSynced([enc['id'] as int]);
          } else if (response.statusCode >= 400 && response.statusCode < 500) {
            final reason = _extractErrorMessage(response.body);
            debugPrint('Client error syncing encoding ${enc['id']}: $reason');
            await _localDb.markEncodingsAsFailed([enc['id'] as int], reason);
          } else {
            debugPrint(
              'Failed to sync encoding ${enc['id']}: ${response.body}',
            );
            DeviceReportingService.instance.reportError(
              'Server error syncing face encoding: HTTP ${response.statusCode}',
              context: 'syncEncodings encoding=${enc['id']} body=${response.body}',
            );
          }
        } catch (e) {
          debugPrint('Failed to sync encoding ${enc['id']}: $e');
          DeviceReportingService.instance.reportError(
            'Failed to sync face encoding: $e',
            context: 'syncEncodings encoding=${enc['id']}',
          );
        }
      }
    } finally {
      _syncingEncodings = false;
    }
  }

  /// Starts a periodic background sync for employees and logs.
  ///
  /// The tick itself is short (30s default) — not because most of the work
  /// needs to run that often, but because pingServer() is the only check in
  /// this whole class that verifies *real* internet reachability rather than
  /// just "a WiFi/cellular radio is associated" (see isOnline). A device that
  /// stays connected to the office WiFi through a brief upstream outage never
  /// fires Connectivity().onConnectivityChanged at all — the transport type
  /// never changes — so this tick was the only thing that would ever notice
  /// the internet came back, and at the old 5-minute interval a scan could
  /// sit as "still waiting to sync" for most of that window even though the
  /// device had a real connection again well before the tick ran. Heavier
  /// full-roster/reconcile work stays throttled to its own slower cadence
  /// (see _lastEmployeeSyncAt/_lastReconcileAt) so the shorter tick doesn't
  /// turn into a standing employee-list re-download every 30 seconds.
  ///
  /// Safe to call multiple times (previous timer will be cancelled).
  void startBackgroundSync({
    Duration tickInterval = const Duration(seconds: 30),
  }) {
    try {
      _syncTimer?.cancel();

      // Attempt to ping server and run an initial sync (handles cold start)
      _attemptPingAndSync();

      // Periodic background sync: verify server reachable before syncing
      _syncTimer = Timer.periodic(tickInterval, (_) async {
        try {
          if (await checkConnectivityStatus()) {
            final now = DateTime.now();

            final lastEmployeeSync = _lastEmployeeSyncAt;
            if (lastEmployeeSync == null ||
                now.difference(lastEmployeeSync) > _employeeSyncInterval) {
              _lastEmployeeSyncAt = now;
              await syncEmployees();
            }

            // Sequenced, not parallel: syncScanEvents() links each scan's
            // evidence row to its attendance log by client_event_id, and
            // that link can only be made once the log actually exists
            // server-side — see the comment on recordAttendance's own sync
            // trigger for the full "None attendance record" story.
            await syncLogs();
            await syncEncodings();
            if (!_scanBackoffActive) await syncScanEvents();
            await DeviceReportingService.instance.syncPendingErrorReports();

            // Hourly, not per-tick: it checks the whole settled queue, and
            // the disagreement it looks for accumulates slowly.
            final lastReconcile = _lastReconcileAt;
            if (lastReconcile == null ||
                now.difference(lastReconcile) > _reconcileInterval) {
              _lastReconcileAt = now;
              await reconcileWithServer();
              await _localDb.trimOldScanThumbnails();
            }

            await _reportSyncHeartbeat();
          } else {
            debugPrint('Background sync skipped: server unreachable');
          }
        } catch (e) {
          debugPrint('Background sync tick failed: $e');
        }
      });

      // Lives here (service-level singleton) rather than on any one screen,
      // so a reconnect is caught regardless of which screen happens to be
      // active — the periodic timer above would otherwise be the only
      // catch-up path, up to 5 minutes after the network actually returns.
      _reconnectSyncSubscription?.cancel();
      _reconnectSyncSubscription = Connectivity().onConnectivityChanged.listen((
        results,
      ) {
        final isConnected = results.any((r) => r != ConnectivityResult.none);
        final justReconnected = isConnected && !_wasOnline;
        _wasOnline = isConnected;
        if (!isConnected) {
          // Cheap and instant — no need to wait for the next ping tick (up
          // to 30s away) to tell the UI the radio just dropped.
          connectivityStatus.value = ConnectivityStatus.noConnection;
        }
        if (justReconnected) {
          // Not awaited: this only exists to resolve the connectivity
          // banner promptly instead of leaving it stale until the next
          // periodic tick — the actual sync work below doesn't depend on it.
          unawaited(checkConnectivityStatus());
          // Backoff is for a server that's failing, not for a device that
          // just got its network back — clear it so the queue drains now.
          _scanBackoff = Duration.zero;
          _scanBackoffUntil = null;
          Future.wait([
            // Missing here previously: a device whose very first sync
            // attempt failed (paired while briefly online, or offline from
            // the start) had no roster and no way to get one except the
            // periodic timer eventually retrying — up to 5 minutes later —
            // or someone manually opening the Employee List screen. This is
            // the actual fix for "employees can't be recognized offline"
            // when the real cause was "the roster was never downloaded",
            // not that matching itself needs a connection.
            syncEmployees().catchError((e) {
              debugPrint('Reconnect sync (employees) failed: $e');
            }),
            syncEncodings().catchError((e) {
              debugPrint('Reconnect sync (encodings) failed: $e');
            }),
            DeviceReportingService.instance.syncPendingErrorReports().catchError((e) {
              debugPrint('Reconnect sync (error reports) failed: $e');
            }),
            // Sequenced with each other (not folded into the Future.wait
            // above) for the same reason as everywhere else scan events sync:
            // syncScanEvents() links to an attendance log that has to exist
            // first, so it must run after syncLogs() actually finishes, not
            // just alongside it.
            () async {
              try {
                await syncLogs();
              } catch (e) {
                debugPrint('Reconnect sync (logs) failed: $e');
              }
              try {
                await syncScanEvents();
              } catch (e) {
                debugPrint('Reconnect sync (scan events) failed: $e');
              }
            }(),
          ]).then((_) => _reportSyncHeartbeat());
        }
      });
    } catch (e) {
      debugPrint('Failed to start background sync: $e');
    }
  }

  /// Stops all syncing and destroys the cached roster because this device no
  /// longer has a valid claim to serve it — a company mismatch, a revoked
  /// credential (server 401s the key outright), or someone deliberately
  /// unpairing it from Settings all land here.
  ///
  /// The window this closes: between a device losing its binding and its
  /// next successful sync, it still holds the previous company's employee
  /// names, photos, and face vectors, and offline matching would happily keep
  /// recognising them. Server-side writes were already fail-closed, so this
  /// is about the data sitting on the device, not about forged attendance.
  /// Public (not the leading-underscore it used to be) so a manual unpair
  /// from Settings can reuse the exact same cleanup instead of duplicating it.
  Future<void> haltSyncAndPurgeRoster({String? reportReason}) async {
    debugPrint('Halting sync and purging roster${reportReason != null ? ' ($reportReason)' : ''}');

    // Stop the periodic timer and reconnect listener first, so nothing
    // re-populates the cache we're about to clear.
    _syncTimer?.cancel();
    _syncTimer = null;
    await _reconnectSyncSubscription?.cancel();
    _reconnectSyncSubscription = null;

    try {
      final removed = await _localDb.purgeTenantRoster();
      if (reportReason != null) {
        await DeviceReportingService.instance.reportError(
          '$reportReason — purged $removed cached employees',
          level: 'error',
          context: ProvisioningService.instance.mismatchDetail,
        );
      }
    } catch (e) {
      debugPrint('Failed to purge roster: $e');
    }
  }

  /// Ping the Next.js backend to wake it up or check status.
  /// Returns true if the server responds with HTTP 200 within timeout.
  Future<bool> pingServer({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/ping');
      final response = await http
          .get(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        Map<String, dynamic>? body;
        try {
          body = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (e) {
          debugPrint('Ping response not valid JSON: $e');
        }

        try {
          final name = body?['company_name'] as String?;
          if (name != null) companyName.value = name;

          // The binding check. If this device's key now resolves to a
          // different company than the one it was paired with, it is holding
          // the previous tenant's roster and face vectors — which would
          // otherwise keep matching their employees offline. Stop everything
          // and purge that cache before it can be used.
          final serverCompanyId = body?['company_id'] as int?;
          if (!ProvisioningService.instance.verifyCompany(serverCompanyId, name)) {
            await haltSyncAndPurgeRoster(reportReason: 'Device company mismatch');
            return false;
          }
        } catch (e) {
          debugPrint('Ping response missing/invalid company_name: $e');
        }

        try {
          await SettingsService().applyServerLocation(
            body?['location'] as Map<String, dynamic>?,
          );
        } catch (e) {
          debugPrint('Ping response missing/invalid location: $e');
        }
        return true;
      }

      // 401 specifically means resolveKioskCompany() found no match for this
      // key at all — not "wrong company" (that's a 200 with a different
      // company_id, handled above), but "this credential doesn't exist
      // anymore." An admin deleted/revoked the device, or (fleet-wide) the
      // legacy shared key was disabled. Either way, the fix is the same as a
      // company mismatch: purge and prompt for a fresh pairing code, rather
      // than leaving this looking like an ordinary connectivity failure
      // forever (which is what happened before — pingServer() just returned
      // false, and the offline banner said "can't reach the server" no
      // matter how long the credential had been dead).
      if (response.statusCode == 401) {
        ProvisioningService.instance.markRevoked();
        await haltSyncAndPurgeRoster(reportReason: 'Device credential revoked');
        return false;
      }

      debugPrint('Ping server returned ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('Ping server failed: $e');
      return false;
    }
  }

  void _attemptPingAndSync([int attemptsRemaining = 3]) async {
    try {
      final ok = await checkConnectivityStatus();
      if (ok) {
        // Server is up — perform initial syncs
        syncEmployees();
        syncLogs();
        syncEncodings();
        _reportSyncHeartbeat();
      } else {
        if (attemptsRemaining > 0) {
          debugPrint(
            'Ping failed — retrying in 10s (${attemptsRemaining - 1} left)',
          );
          Timer(
            Duration(seconds: 10),
            () => _attemptPingAndSync(attemptsRemaining - 1),
          );
        } else {
          debugPrint('Ping failed after retries — will rely on periodic sync');
        }
      }
    } catch (e) {
      debugPrint('Attempt ping and sync failed: $e');
    }
  }

  // --- Core Features ---

  Future<void> saveFaceDescriptor(
    int employeeId,
    List<double> embedding, {
    bool isGolden = false,
  }) async {
    if (!await isOnline) {
      debugPrint('Offline: saving face descriptor locally');
      await _localDb.insertOfflineEncoding(
        employeeId,
        embedding,
        isGolden: isGolden,
      );
      return;
    }

    try {
      final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/face-encoding');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': ProvisioningService.instance.apiKey,
        },
        body: jsonEncode({
          'employeeId': employeeId,
          'descriptor': embedding,
          'isGolden': isGolden,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to save encoding: ${response.statusCode} ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Error saving face descriptor: $e');
      // Fallback to offline storage on any error
      await _localDb.insertOfflineEncoding(
        employeeId,
        embedding,
        isGolden: isGolden,
      );
    }
  }

  Future<void> deleteFaceEncodings(int employeeId) async {
    if (!await isOnline) {
      throw Exception("Cannot delete dataset while offline");
    }

    try {
      final url = Uri.parse(
        '${AppConfig.nextJsBaseUrl}/api/face-encoding?employeeId=$employeeId',
      );
      final response = await http.delete(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': ProvisioningService.instance.apiKey,
        },
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to delete encodings: ${response.statusCode} ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Error deleting face encodings: $e');
      rethrow;
    }
  }

  // --- Helper: Fast dot product for pre-normalized vectors ---

  /// Fast dot product - for pre-normalized vectors, this IS the cosine similarity
  static double _fastDotProduct(List<double> vec1, List<double> vec2) {
    if (vec1.length != vec2.length) return -1.0;
    double result = 0.0;
    for (int i = 0; i < vec1.length; i++) {
      result += vec1[i] * vec2[i];
    }
    return result;
  }

  Future<Map<String, dynamic>?> verifyFace(List<double> embedding) async {
    // Normalize input embedding
    double norm = 0;
    for (var x in embedding) {
      norm += x * x;
    }
    norm = sqrt(norm);
    if (norm < 1e-10) return null;

    final normalizedEmbedding = embedding.map((x) => x / norm).toList();

    // Prefer LOCAL verification first using pre-normalized vectors (FAST)
    debugPrint('Attempting Local Verification with cached vectors...');
    final employees = await _localDb.getAllEmployees();
    double maxScore = -1.0;
    Map<String, dynamic>? bestMatch;

    for (var emp in employees) {
      final empId = emp['id'] as int;

      // Get pre-cached normalized vectors with golden metadata
      final cachedEntries = await _localDb.getCachedVectorEntriesForEmployee(
        empId,
      );
      if (cachedEntries.isEmpty) continue;

      for (final entry in cachedEntries) {
        final vectorList = entry['vector'] as List<double>;
        final isGolden = entry['isGolden'] as bool;

        // Fast dot product (no need to normalize again - vectors are pre-normalized)
        double score = _fastDotProduct(normalizedEmbedding, vectorList);

        // Golden encodings get a small boost to prioritize high-quality reference data.
        // Boost is 5% so a golden score of 0.952+ beats a non-golden 1.0 only when close.
        if (isGolden) score = (score * 1.05).clamp(-1.0, 1.0);

        if (score > maxScore) {
          maxScore = score;
          bestMatch = emp;
        }
      }
    }

    if (maxScore >= 0.7 && bestMatch != null) {
      return {
        'id': bestMatch['id'],
        'first_name': bestMatch['first_name'],
        'last_name': bestMatch['last_name'],
        'position': bestMatch['position'],
        'similarity': maxScore,
      };
    }

    // Local didn't find a match. If online, fall back to a server-side match
    // via the Next.js API (and trigger background sync if successful).
    //
    // This used to call Supabase's `match_face` RPC directly via _client.rpc,
    // bypassing the Next.js API entirely and querying with the anon key,
    // which has no per-tenant identity — a face captured at one company's
    // kiosk could match an employee belonging to a different company once
    // multiple companies shared that RPC's table. Routing through
    // /api/match-face instead means the kiosk's own x-api-key resolves the
    // company server-side (see resolveKioskCompany in the Next.js app), the
    // same way every other mobile endpoint already works, and it stays
    // scoped even in local dev against a database Supabase's own RPC
    // wouldn't know about.
    if (await isOnline) {
      try {
        final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/match-face');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': ProvisioningService.instance.apiKey,
          },
          body: jsonEncode({
            'query_embedding': normalizedEmbedding,
            'match_threshold': 0.7,
            'match_count': 1,
          }),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'Match face request failed: ${response.statusCode} ${response.body}',
          );
        }

        final List<dynamic> results = jsonDecode(response.body);
        if (results.isEmpty) return null;

        final match = results.first as Map<String, dynamic>;

        // Trigger a background sync so local cache is updated for future offline/fast lookups.
        syncEmployees();

        return {
          'id': match['employee_id'],
          'first_name': match['first_name'],
          'last_name': match['last_name'],
          'position': match['position'],
          'similarity': match['similarity'],
        };
      } catch (e) {
        debugPrint('Online verification failed: $e');
      }
    }

    return null;
  }

  /// Signs in and confirms the account may administer *this* kiosk.
  ///
  /// A valid Supabase session is not sufficient on its own. Supabase Auth is
  /// shared across the whole platform, so accepting any successful sign-in —
  /// which is what this used to do — let one company's admin open another
  /// company's kiosk with their own credentials, reaching the admin dashboard
  /// and employee/face registration, and (via the NetworkGuard failure
  /// screen's login) bypassing the WiFi/geofence lockout entirely.
  ///
  /// The session only proves who they are. Whether they administer the
  /// company this device is paired to is decided by the server against
  /// company_members, because the device cannot be trusted to enforce a
  /// tenant boundary about itself.
  Future<bool> loginAdmin(String email, String password) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final accessToken = response.session?.accessToken;
      if (accessToken == null) return false;

      final authorized = await _isAuthorizedKioskAdmin(accessToken);
      if (!authorized) {
        // The credentials were genuine, so without this the rejected user is
        // left holding a live Supabase session on someone else's kiosk.
        await _client.auth.signOut();
      }
      return authorized;
    } catch (e) {
      debugPrint('Error logging in admin: $e');
      // Never leave a half-completed sign-in behind on a shared device.
      try {
        await _client.auth.signOut();
      } catch (_) {}
      return false;
    }
  }

  /// Asks the server whether the signed-in account administers this device's
  /// company. Fails closed: anything other than an explicit yes is a no.
  ///
  /// That includes the offline case. Admin access unlocks the roster and the
  /// location-enforcement settings, so "we couldn't check" must not read as
  /// "allowed" — and sign-in already requires connectivity anyway, so this
  /// costs nothing that was previously available.
  Future<bool> _isAuthorizedKioskAdmin(String accessToken) async {
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.nextJsBaseUrl}/api/kiosk/admin-auth'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
            body: jsonEncode({'accessToken': accessToken}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return body['authorized'] == true;
      }

      debugPrint(
        'Kiosk admin authorization refused: HTTP ${response.statusCode} ${response.body}',
      );
      return false;
    } catch (e) {
      debugPrint('Kiosk admin authorization check failed: $e');
      return false;
    }
  }

  Future<int> registerEmployee(
    Map<String, dynamic> employeeData,
    List<double> embedding,
  ) async {
    try {
      final employeeId = await _createEmployee(employeeData);
      await saveFaceDescriptor(employeeId, embedding, isGolden: true);

      // Trigger sync to update local cache immediately
      syncEmployees();

      return employeeId;
    } catch (e) {
      debugPrint('Error registering employee: $e');
      rethrow;
    }
  }

  /// Creates the employee record via the Next.js API (follows
  /// AppConfig.nextJsBaseUrl — local dev server or production).
  Future<int> _createEmployee(Map<String, dynamic> employeeData) async {
    final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/employees');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ProvisioningService.instance.apiKey,
      },
      body: jsonEncode(employeeData),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create employee: ${response.statusCode} ${response.body}',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['id'] as int;
  }

  /// What attendance type the next punch will record for [employeeId]. One of:
  /// - `'time-in'`      : not yet timed in today
  /// - `'time-out'`     : timed in but not out yet
  /// - `'overtime-in'`  : completed regular shift, overtime not started
  /// - `'overtime-out'` : overtime session is active
  /// - `'done'`         : regular shift + overtime both complete
  ///
  /// Returns `null` if the state genuinely can't be determined, which the UI
  /// treats as "offer both punches" rather than guessing.
  ///
  /// Asks the server first, because the local answer is only as good as this
  /// device's own punch history. A reinstalled app, an employee who timed in
  /// on a different kiosk, or an overtime session still open from *yesterday*
  /// (which [LocalDatabaseService.hasLogForToday] cannot see, being scoped to
  /// today) all read locally as "hasn't timed in yet". The local computation
  /// stays as the offline fallback — it's the right answer for the common
  /// single-kiosk case, and a kiosk with no connectivity still has to work.
  /// The server's verdict on what this employee should punch next, or null if
  /// it couldn't be reached. Authoritative when it answers: it sees every
  /// kiosk and any overtime session still open from a previous day.
  ///
  /// Short timeout on purpose. Someone is standing at the kiosk waiting, and
  /// a working office LAN answers this in well under a second. Giving up
  /// early only costs a fallback to the local estimate — far cheaper than
  /// making every employee wait out a long timeout on the flaky WiFi where
  /// this matters most.
  Future<String?> _serverNextAction(int employeeId) async {
    if (!await isOnline) return null;
    try {
      final response = await http
          .get(
            Uri.parse(
              '${AppConfig.nextJsBaseUrl}/api/attendance/status'
              '?employeeId=$employeeId',
            ),
            headers: {'x-api-key': ProvisioningService.instance.apiKey},
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final action = body['nextAction'] as String?;
        if (action != null && action.isNotEmpty) return action;
      } else {
        debugPrint(
          'nextAction: server returned ${response.statusCode}, using local state',
        );
      }
    } catch (e) {
      debugPrint('nextAction: server lookup failed ($e)');
    }
    return null;
  }

  Future<({String? action, bool authoritative})> getEmployeeNextAction(
    int employeeId,
  ) async {
    final serverAction = await _serverNextAction(employeeId);
    if (serverAction != null) {
      return (action: serverAction, authoritative: true);
    }

    // Everything below is an estimate from this device's own punch history,
    // so it comes back marked non-authoritative. It is right for the ordinary
    // single-kiosk day and wrong in exactly the cases the server exists to
    // cover: a reinstalled app, an employee who punched on another kiosk, or
    // an overtime session still open from yesterday — all of which read here
    // as "hasn't timed in yet". The caller must keep both punches reachable
    // on an estimate, or an offline kiosk would refuse to let a real employee
    // clock out.
    try {
      final hasTimedIn = await _localDb.hasLogForToday(employeeId, 'time-in');
      final hasTimedOut = await _localDb.hasLogForToday(employeeId, 'time-out');

      String action;
      if (!hasTimedIn) {
        action = 'time-in';
      } else if (!hasTimedOut) {
        action = 'time-out';
      } else {
        // Completed regular shift — check overtime state
        final hasOvertimeIn =
            await _localDb.hasLogForToday(employeeId, 'overtime-in');
        final hasOvertimeOut =
            await _localDb.hasLogForToday(employeeId, 'overtime-out');

        if (!hasOvertimeIn) {
          action = 'overtime-in';
        } else if (!hasOvertimeOut) {
          action = 'overtime-out';
        } else {
          action = 'done';
        }
      }
      return (action: action, authoritative: false);
    } catch (e) {
      debugPrint('getEmployeeNextAction: local DB error: $e');
      return (action: null, authoritative: false);
    }
  }

  /// Records an attendance action and its evidence.
  ///
  /// [scanThumbnail] is a base64 JPEG crop of the face that was matched, and
  /// [matchConfidence]/[livenessPassed] describe how it was matched. They're
  /// stored alongside the attendance row so a later dispute has something
  /// concrete to look at rather than just an absence of a record.
  ///
  /// Returns the **effective** attendance type that was actually recorded
  /// (e.g. `'overtime-in'` when the caller passed `'time-in'` but a regular
  /// shift was already complete) — the caller should use this, not the type
  /// it passed in, when presenting the outcome to the user — plus the
  /// `clientEventId` this punch was recorded under, so the caller can poll
  /// [getPunchSyncState] to find out whether it actually reached the server
  /// yet rather than assuming the local save means it's confirmed.
  Future<({String effectiveType, String clientEventId})> recordAttendance(
    int employeeId,
    String type, {
    String? employeeName,
    String? scanThumbnail,
    double? matchConfidence,
    bool? livenessPassed,
  }) async {
    // Detect overtime scenario: employee has already completed a regular shift today
    String effectiveType = type;

    if (type == 'time-in') {
      final hasTimedIn = await _localDb.hasLogForToday(employeeId, 'time-in');
      final hasTimedOut = await _localDb.hasLogForToday(employeeId, 'time-out');

      if (hasTimedIn && hasTimedOut) {
        // Employee completed regular shift — this is an overtime-in
        final hasOvertimeIn = await _localDb.hasLogForToday(
          employeeId,
          'overtime-in',
        );
        final hasOvertimeOut = await _localDb.hasLogForToday(
          employeeId,
          'overtime-out',
        );

        if (hasOvertimeIn && !hasOvertimeOut) {
          throw Exception(
            "You already have an active overtime session. Please time out from overtime first.",
          );
        }

        if (hasOvertimeIn && hasOvertimeOut) {
          throw Exception(
            "You have already completed an overtime session today. Only one overtime session per day is allowed.",
          );
        }

        effectiveType = 'overtime-in';
      } else if (hasTimedIn && !hasTimedOut) {
        throw Exception(
          "Attendance already recorded today (time-in). Please time out first.",
        );
      }
    } else if (type == 'time-out') {
      final hasTimedIn = await _localDb.hasLogForToday(employeeId, 'time-in');
      final hasTimedOut = await _localDb.hasLogForToday(employeeId, 'time-out');

      if (hasTimedOut) {
        // Already timed out — check for overtime-out scenario
        final hasOvertimeIn = await _localDb.hasLogForToday(
          employeeId,
          'overtime-in',
        );
        final hasOvertimeOut = await _localDb.hasLogForToday(
          employeeId,
          'overtime-out',
        );

        if (hasOvertimeIn && !hasOvertimeOut) {
          effectiveType = 'overtime-out';
        } else if (hasOvertimeIn && hasOvertimeOut) {
          throw Exception(
            "You have already completed an overtime session today.",
          );
        } else {
          // Local history says there's no session to close — but it is only
          // this device's view, and it is wrong in the case that matters
          // most. hasLogForToday() ignores rows carrying a sync_error, so a
          // single rejected overtime-in upload erases the session from the
          // device's memory while the server keeps it open. That is not
          // hypothetical: overtime punches had no idempotency key, so a
          // retried upload was refused as a duplicate, and the employee was
          // then locked out of the overtime-out permanently.
          //
          // The server holds the real answer, so ask it before refusing.
          final serverAction = await _serverNextAction(employeeId);
          if (serverAction == 'overtime-out') {
            effectiveType = 'overtime-out';
          } else {
            throw Exception(
              "You have already timed out and have no active overtime session.",
            );
          }
        }
      } else if (!hasTimedIn) {
        final online = await isOnline;
        if (!online) {
          throw Exception("Cannot time-out without a prior time-in today.");
        }
      }
    }

    final now = DateTime.now().toUtc();

    // Best-effort — capture what's true right now (not at whatever later
    // moment this record finally syncs), degrading gracefully if location
    // services are off/denied. Read in parallel so this doesn't add up
    // the individual timeouts on top of each other.
    GeoReading? geo;
    String? ssid;
    String? bssid;
    try {
      final results = await Future.wait([
        _networkService.getCurrentGeoReading(),
        _networkService.getCurrentSSID(),
        _networkService.getCurrentBSSID(),
      ]);
      geo = results[0] as GeoReading?;
      ssid = results[1] as String?;
      bssid = results[2] as String?;
    } catch (e) {
      debugPrint('recordAttendance: failed to read location/wifi signals: $e');
    }

    // One id ties the attendance row and its evidence row together, and is
    // what makes the upload safely repeatable. Generated here — before any
    // network call — so a crash mid-sync doesn't produce a second attempt
    // with a different identity.
    final clientEventId = _uuid.v4();

    // The app version is loaded lazily from PackageInfo on first use. Without
    // this, the very first punch after a cold start would race that load and
    // be stamped null — precisely the punch most worth attributing after a
    // bad release. Cheap and idempotent once loaded.
    await DeviceReportingService.instance.ensureIdentity();

    // Written first: if the process dies between here and the attendance
    // insert, we still have proof the scan happened.
    await _localDb.insertScanEvent(
      clientEventId: clientEventId,
      scannedAt: now,
      outcome: 'pending_sync',
      employeeId: employeeId,
      employeeName: employeeName,
      attendanceType: effectiveType,
      matchConfidence: matchConfidence,
      livenessPassed: livenessPassed,
      thumbnail: scanThumbnail,
      lat: geo?.latitude,
      lng: geo?.longitude,
      wifiSsid: ssid,
      wifiBssid: bssid,
    );

    // Always save to the local database immediately to provide instant feedback
    await _localDb.insertOfflineLog(
      employeeId,
      effectiveType,
      now,
      lat: geo?.latitude,
      lng: geo?.longitude,
      isMocked: geo?.isMocked,
      wifiSsid: ssid,
      wifiBssid: bssid,
      clientEventId: clientEventId,
      // Captured now, not at upload time: a log that waits in the queue
      // through a Shorebird patch would otherwise be attributed to the build
      // that finally uploaded it rather than the one that recorded it.
      appVersion: DeviceReportingService.instance.appVersion,
    );

    // Fire and forget background sync to upload the log without blocking the
    // user — but sequenced, not concurrent. syncScanEvents() links each scan
    // evidence row to its attendance log by client_event_id; if it beat
    // syncLogs() to the server, the attendance log wouldn't exist yet to link
    // to, and since the evidence row is marked uploaded either way, it never
    // gets a second chance — it'd show "no attendance record" on the
    // dashboard permanently, for a log that actually did land. Running
    // syncLogs() first — and awaiting it — means the attendance log has
    // already had its chance to reach the server before the evidence upload
    // even starts. (The server also links from its own side now as a second
    // line of defense, but there's no reason to lean on that when avoiding
    // the race here is free.)
    isOnline.then((online) async {
      if (!online) return;
      try {
        await syncLogs();
      } catch (e) {
        debugPrint('Background sync failed after recordAttendance: $e');
      }
      try {
        await syncScanEvents();
      } catch (e) {
        debugPrint('Scan event sync failed after recordAttendance: $e');
      }
    });

    return (effectiveType: effectiveType, clientEventId: clientEventId);
  }

  /// Records a scan that never became an attendance action at all — no
  /// match, a failed liveness check, or a matched-and-live face that
  /// [recordAttendance] declined to write (e.g. `'device_rejected'` for an
  /// employee who already timed in today). These previously left no trace,
  /// which is exactly the gap someone points at when they say they scanned
  /// and nothing happened.
  Future<void> recordFailedScan({
    required String outcome,
    String? thumbnail,
    int? employeeId,
    String? employeeName,
    double? matchConfidence,
    bool? livenessPassed,
    String? reason,
  }) async {
    try {
      await _localDb.insertScanEvent(
        clientEventId: _uuid.v4(),
        scannedAt: DateTime.now().toUtc(),
        outcome: outcome,
        employeeId: employeeId,
        employeeName: employeeName,
        matchConfidence: matchConfidence,
        livenessPassed: livenessPassed,
        thumbnail: thumbnail,
        rejectionReason: reason,
      );
    } catch (e) {
      // Evidence recording must never block or break the scan UI.
      debugPrint('Failed to record scan evidence: $e');
    }
  }

  Future<String> uploadEmployeePhoto(int employeeId, File imageFile) async {
    if (!await isOnline) {
      throw Exception("Cannot upload: Check internet connection");
    }

    try {
      final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/employees/photo');
      final request = http.MultipartRequest('POST', url)
        ..headers['x-api-key'] = ProvisioningService.instance.apiKey
        ..fields['employeeId'] = employeeId.toString()
        ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to upload photo: ${response.statusCode} ${response.body}',
        );
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['url'] as String;
    } catch (e) {
      debugPrint('Error uploading photo: $e');
      throw Exception('Photo upload failed: ${e.toString()}');
    }
  }

  Future<int> registerEmployeeWithPhotos(
    Map<String, dynamic> employeeData,
    List<String> photoPaths,
  ) async {
    if (!await isOnline) {
      throw Exception("Registration requires internet connection");
    }

    if (photoPaths.isEmpty) {
      throw Exception("No photos provided for registration");
    }

    int? employeeId;
    try {
      // 1. Insert Employee Record (without embedding initially)
      employeeId = await _createEmployee(employeeData);

      // 2. Upload Profile Picture (Use the first photo as primary)
      String? uploadedPhotoUrl;
      try {
        uploadedPhotoUrl = await uploadEmployeePhoto(
          employeeId,
          File(photoPaths.first),
        );
      } catch (e) {
        debugPrint("Warning: Failed to upload profile picture: $e");
      }

      // 3. Update employee record with image_url if photo was uploaded
      if (uploadedPhotoUrl != null) {
        try {
          final url = Uri.parse(
            '${AppConfig.nextJsBaseUrl}/api/employees?id=$employeeId',
          );
          await http.patch(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ProvisioningService.instance.apiKey,
            },
            body: jsonEncode({'image_url': uploadedPhotoUrl}),
          );
        } catch (e) {
          debugPrint("Warning: Failed to update employee image_url: $e");
        }
      }

      // 4. Process All Photos -> Generate Embeddings -> Save as Golden
      final FaceService faceService = FaceService();
      // Ensure initialized
      await faceService.initialize();

      int successfulEncodings = 0;

      for (final path in photoPaths) {
        try {
          final embedding = await faceService.getFaceEmbeddingFromFile(path);
          if (embedding != null) {
            await saveFaceDescriptor(employeeId, embedding, isGolden: true);
            successfulEncodings++;
          }
        } catch (e) {
          debugPrint("Error processing photo $path: $e");
        }
      }

      if (successfulEncodings == 0) {
        throw Exception(
          "Failed to extract face data from any of the provided photos",
        );
      }

      // 4. Sync so the local cache (and home screen) reflects the new
      // employee/photo immediately instead of waiting for the next
      // background sync cycle.
      await syncEmployees();

      return employeeId;
    } catch (e) {
      debugPrint('Registration with photos failed: $e');
      if (employeeId != null) {
        try {
          final url = Uri.parse(
            '${AppConfig.nextJsBaseUrl}/api/employees?id=$employeeId',
          );
          await http.delete(
            url,
            headers: {'x-api-key': ProvisioningService.instance.apiKey},
          );
        } catch (deleteError) {
          debugPrint(
            'CRITICAL: Failed to rollback employee $employeeId: $deleteError',
          );
        }
      }
      rethrow;
    }
  }

  // ---------------------------------------------------------
  // Employee Selection & Photo Fetching
  // ---------------------------------------------------------

  /// Fetches employees with photo URLs for the searchable selector.
  /// Reads from SQLite first for instant load, then syncs in background.
  Future<List<Map<String, dynamic>>> fetchEmployeesWithPhotos() async {
    // First, try to load from local SQLite for instant response
    final localEmployees = await _localDb.getAllEmployees();
    if (localEmployees.isNotEmpty) {
      // Trigger background sync for next time, but don't wait
      syncEmployees();
      return _mapLocalEmployees(localEmployees);
    }

    // Local cache is empty (e.g. first launch on this device) — sync via
    // the Next.js API (same path as syncEmployees()/AppConfig.nextJsBaseUrl,
    // so this transparently follows whatever server the app is pointed at —
    // production or a local dev server — instead of querying Supabase
    // directly and bypassing that config).
    if (!await isOnline) {
      return [];
    }

    await syncEmployees();
    final synced = await _localDb.getAllEmployees();
    return _mapLocalEmployees(synced);
  }

  List<Map<String, dynamic>> _mapLocalEmployees(
    List<Map<String, dynamic>> localEmployees,
  ) {
    return localEmployees
        .map(
          (emp) => <String, dynamic>{
            'id': emp['id'],
            'first_name': emp['first_name'] ?? '',
            'last_name': emp['last_name'] ?? '',
            'position': emp['position'] ?? '',
            'photo_url': emp['image_url'],
            // Carried through so the avatar can come off disk. The photos
            // are already downloaded and cached here (see
            // updateEmployeeLocalImagePath), but dropping the path at this
            // boundary left every consumer falling back to a network fetch
            // — which on an offline kiosk means no faces at all, at exactly
            // the moment someone needs to confirm the kiosk picked the
            // right person.
            'local_image_path': emp['local_image_path'],
          },
        )
        .toList();
  }

  /// Verifies a face embedding against ALL encodings of a specific employee.
  /// Returns the best similarity score, or null if no match.
  /// Whether this device actually holds face data for [employeeId].
  ///
  /// Distinguishes the two ways [verifyFaceAgainstEmployee] returns null. One
  /// means the face on camera is not this employee; the other means the
  /// device was never given their face to compare against — an employee
  /// enrolled after this kiosk last synced, or enrolled on another device.
  /// Offline they look identical from the outside, because the online
  /// fallback that would have papered over the second case is unreachable.
  ///
  /// Recording both as "no match" told the employer that somebody's face
  /// failed verification when nothing was ever verified, and the remedy for
  /// the two is opposite: re-enrol the face, or sync the device.
  Future<bool> hasCachedFaceFor(int employeeId) async {
    final vectors = await _localDb.getCachedVectorsForEmployee(employeeId);
    return vectors.isNotEmpty;
  }

  Future<Map<String, dynamic>?> verifyFaceAgainstEmployee(
    List<double> embedding,
    int employeeId,
  ) async {
    // Normalize input embedding
    double norm = 0;
    for (var x in embedding) {
      norm += x * x;
    }
    norm = sqrt(norm);
    if (norm < 1e-10) return null;

    final normalizedEmbedding = embedding.map((x) => x / norm).toList();

    // Prefer OFFLINE verification for speed using pre-normalized vectors
    debugPrint(
      'Using Offline Targeted Verification for employee $employeeId with cached vectors...',
    );

    // Get pre-cached normalized vectors
    final cachedVectors = await _localDb.getCachedVectorsForEmployee(
      employeeId,
    );

    if (cachedVectors.isNotEmpty) {
      double maxScore = -1.0;

      for (final vectorList in cachedVectors) {
        // Fast dot product (vectors are pre-normalized)
        final score = _fastDotProduct(normalizedEmbedding, vectorList);
        if (score > maxScore) {
          maxScore = score;
        }
      }

      if (maxScore >= 0.6) {
        final emp = await _localDb.getEmployee(employeeId);
        if (emp != null) {
          return {
            'id': emp['id'],
            'first_name': emp['first_name'],
            'last_name': emp['last_name'],
            'position': emp['position'],
            'similarity': maxScore,
          };
        }
      }
    }

    // Local verification didn't confirm. If online, fall back to a server-
    // side match via the Next.js API (follows AppConfig.nextJsBaseUrl, so
    // this checks whichever database the app is actually pointed at,
    // instead of always querying production Supabase directly).
    if (await isOnline) {
      try {
        final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/match-face');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': ProvisioningService.instance.apiKey,
          },
          body: jsonEncode({
            'query_embedding': normalizedEmbedding,
            'match_threshold': 0.6,
            'match_count': 5,
          }),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'Match face request failed: ${response.statusCode} ${response.body}',
          );
        }

        final List<dynamic> results = jsonDecode(response.body);
        for (final match in results) {
          if (match['employee_id'] == employeeId) {
            // Refresh local cache in background
            syncEmployees();
            return {
              'id': match['employee_id'],
              'first_name': match['first_name'],
              'last_name': match['last_name'],
              'position': match['position'],
              'similarity': match['similarity'],
            };
          }
        }
      } catch (e) {
        debugPrint('Online targeted verification failed: $e');
      }
    }

    return null;
  }
}
