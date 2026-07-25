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
import '../config/app_config.dart';
import 'local_database_service.dart';
import 'face_service.dart';
import 'device_reporting_service.dart';
import 'settings_service.dart';
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

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  final LocalDatabaseService _localDb = LocalDatabaseService();
  final NetworkService _networkService = NetworkService();
  Timer? _syncTimer;
  StreamSubscription<List<ConnectivityResult>>? _reconnectSyncSubscription;
  bool _wasOnline = true;
  bool _syncingLogs = false;
  bool _syncingEncodings = false;

  /// Name of the company this device's MOBILE_API_KEY is provisioned for
  /// (multi-tenant deployment — every device belongs to exactly one
  /// company). Populated by [pingServer]; null until the first successful
  /// ping. A ValueNotifier so screens can reactively show it without
  /// each one re-fetching it themselves.
  final ValueNotifier<String?> companyName = ValueNotifier<String?>(null);

  /// Check internet connectivity
  Future<bool> get isOnline async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.any((r) => r != ConnectivityResult.none);
  }

  // --- Synchronization ---

  /// Syncs employees from Supabase to Local DB (Down Sync)
  Future<void> syncEmployees() async {
    if (!await isOnline) return;

    try {
      // Use the optimized API endpoint to fetch employees with cached/limited encodings
      final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/sync/employees');
      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': AppConfig.mobileApiKey,
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
        final imageUrl = emp['image_url'] as String?;

        // Try to cache both the original image_url and the avatar endpoint
        if (imageUrl != null && imageUrl.isNotEmpty) {
          await _downloadAndCacheEmployeeImage(empId, imageUrl);
        }

        // Also cache from the direct avatar endpoint as a fallback/primary source
        final avatarUrl = AppConfig.getEmployeeAvatarUrl(empId);
        await _downloadAndCacheEmployeeImage(empId, avatarUrl);
      }
    } catch (e) {
      debugPrint('Sync Error: $e');
      DeviceReportingService.instance.reportError(
        'Employee sync failed: $e',
        context: 'syncEmployees',
      );
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

      // If file already exists and is recent, skip re-downloading
      if (await localFile.exists()) {
        try {
          final stat = await localFile.stat();
          final age = DateTime.now().difference(stat.modified);
          // Only re-download if cached file is older than 24 hours
          if (age.inHours < 24) {
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
              headers: {'x-api-key': AppConfig.mobileApiKey},
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
              'x-api-key': AppConfig.mobileApiKey,
            },
            body: jsonEncode({
              'employeeId': log['employee_id'],
              'type': log['type'],
              'time': timeStr,
              'timestamp': timestamp,
              if (log['lat'] != null) 'lat': log['lat'],
              if (log['lng'] != null) 'lng': log['lng'],
              if (log['is_mocked'] != null) 'isMocked': log['is_mocked'] == 1,
              if (log['wifi_ssid'] != null) 'wifiSsid': log['wifi_ssid'],
              if (log['wifi_bssid'] != null) 'wifiBssid': log['wifi_bssid'],
            }),
          );

          if (response.statusCode >= 200 && response.statusCode < 300) {
            // Mark as synced only if successful
            await _localDb.markLogsAsSynced([log['id'] as int]);
          } else if (response.statusCode >= 400 && response.statusCode < 500) {
            // Client error (e.g. 'Already timed in', or too old to sync).
            // Retrying won't fix it, but unlike a real success this must stay
            // visible — silently discarding it would mean this attendance
            // record is gone with no trace anywhere.
            final reason = _extractErrorMessage(response.body);
            debugPrint('Client error syncing log ${log['id']}: $reason');
            await _localDb.markLogsAsFailed([log['id'] as int], reason);
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
              'x-api-key': AppConfig.mobileApiKey,
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
  /// Default interval is 5 minutes. Safe to call multiple times (previous timer will be cancelled).
  void startBackgroundSync({int intervalMinutes = 5}) {
    try {
      _syncTimer?.cancel();

      // Attempt to ping server and run an initial sync (handles cold start)
      _attemptPingAndSync();

      // Periodic background sync: verify server reachable before syncing
      _syncTimer = Timer.periodic(Duration(minutes: intervalMinutes), (
        _,
      ) async {
        try {
          if (await pingServer()) {
            await syncEmployees();
            await syncLogs();
            await syncEncodings();
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
        if (justReconnected) {
          Future.wait([
            syncLogs().catchError((e) {
              debugPrint('Reconnect sync (logs) failed: $e');
            }),
            syncEncodings().catchError((e) {
              debugPrint('Reconnect sync (encodings) failed: $e');
            }),
          ]).then((_) => _reportSyncHeartbeat());
        }
      });
    } catch (e) {
      debugPrint('Failed to start background sync: $e');
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
              'x-api-key': AppConfig.mobileApiKey,
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
      debugPrint('Ping server returned ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('Ping server failed: $e');
      return false;
    }
  }

  void _attemptPingAndSync([int attemptsRemaining = 3]) async {
    try {
      final ok = await pingServer();
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
          'x-api-key': AppConfig.mobileApiKey,
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
          'x-api-key': AppConfig.mobileApiKey,
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
            'x-api-key': AppConfig.mobileApiKey,
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

  Future<bool> loginAdmin(String email, String password) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      return response.session != null;
    } catch (e) {
      debugPrint('Error logging in admin: $e');
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
        'x-api-key': AppConfig.mobileApiKey,
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

  Future<void> recordAttendance(int employeeId, String type) async {
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
          throw Exception(
            "You have already timed out and have no active overtime session.",
          );
        }
      } else if (!hasTimedIn) {
        final online = await isOnline;
        if (!online) {
          throw Exception("Cannot time-out without a prior time-in today.");
        }
      }
    }

    final now = DateTime.now();

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
    );

    // Fire and forget background sync to upload the log without blocking the user
    isOnline.then((online) {
      if (online) {
        syncLogs().catchError((e) {
          debugPrint('Background sync failed after recordAttendance: $e');
        });
      }
    });
  }

  Future<String> uploadEmployeePhoto(int employeeId, File imageFile) async {
    if (!await isOnline) {
      throw Exception("Cannot upload: Check internet connection");
    }

    try {
      final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/employees/photo');
      final request = http.MultipartRequest('POST', url)
        ..headers['x-api-key'] = AppConfig.mobileApiKey
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
              'x-api-key': AppConfig.mobileApiKey,
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
            headers: {'x-api-key': AppConfig.mobileApiKey},
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
          },
        )
        .toList();
  }

  /// Verifies a face embedding against ALL encodings of a specific employee.
  /// Returns the best similarity score, or null if no match.
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
            'x-api-key': AppConfig.mobileApiKey,
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
