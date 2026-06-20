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

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  final LocalDatabaseService _localDb = LocalDatabaseService();
  Timer? _syncTimer;

  /// Check internet connectivity
  Future<bool> get isOnline async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult is List) {
      return (connectivityResult as List).isNotEmpty &&
          !(connectivityResult as List).contains(ConnectivityResult.none);
    }
    return connectivityResult != ConnectivityResult.none;
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
  Future<void> syncLogs() async {
    if (!await isOnline) return;

    final logs = await _localDb.getUnsyncedLogs();
    if (logs.isEmpty) return;

    for (var log in logs) {
      try {
        final timestamp = log['timestamp'] as String;
        final timeStr = timestamp.split('T')[1].substring(0, 8);

        final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/attendance/log');
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
          }),
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          // Mark as synced only if successful
          await _localDb.markLogsAsSynced([log['id'] as int]);
        } else if (response.statusCode >= 400 && response.statusCode < 500) {
          // Client error (e.g. 'Already timed in'). Retrying won't fix it.
          // We mark it as synced to remove it from the pending sync queue.
          debugPrint('Client error syncing log ${log['id']}: ${response.body}');
          await _localDb.markLogsAsSynced([log['id'] as int]);
        } else {
          debugPrint(
            'Failed to sync log ${log['id']} (Server error): ${response.body}',
          );
        }
      } catch (e) {
        debugPrint('Failed to sync log ${log['id']}: $e');
      }
    }
  }

  /// Syncs offline face encodings to Supabase (Up Sync)
  Future<void> syncEncodings() async {
    if (!await isOnline) return;

    final encodings = await _localDb.getUnsyncedEncodings();
    if (encodings.isEmpty) return;

    for (var enc in encodings) {
      try {
        final descriptorStr = enc['descriptor'] as String;
        final descriptor = jsonDecode(descriptorStr) as List<dynamic>;

        final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/face-encoding');
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
          debugPrint(
            'Client error syncing encoding ${enc['id']}: ${response.body}',
          );
          await _localDb.markEncodingsAsSynced([enc['id'] as int]);
        } else {
          debugPrint('Failed to sync encoding ${enc['id']}: ${response.body}');
        }
      } catch (e) {
        debugPrint('Failed to sync encoding ${enc['id']}: $e');
      }
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
          } else {
            debugPrint('Background sync skipped: server unreachable');
          }
        } catch (e) {
          debugPrint('Background sync tick failed: $e');
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

      if (response.statusCode == 200) return true;
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

    // Local didn't find a match. If online, fall back to server RPC (and trigger background sync if successful).
    if (await isOnline) {
      try {
        final vectorStr = '[${normalizedEmbedding.join(',')}]';
        final response = await _client.rpc(
          'match_face',
          params: {
            'query_embedding': vectorStr,
            'match_threshold': 0.7,
            'match_count': 1,
          },
        );

        final List<dynamic> results = response;
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
      final employeeResponse = await _client
          .from('employees')
          .insert(employeeData)
          .select()
          .single();

      final employeeId = employeeResponse['id'] as int;
      await saveFaceDescriptor(employeeId, embedding, isGolden: true);

      // Trigger sync to update local cache immediately
      syncEmployees();

      return employeeId;
    } catch (e) {
      debugPrint('Error registering employee: $e');
      rethrow;
    }
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

    // Always save to the local database immediately to provide instant feedback
    await _localDb.insertOfflineLog(employeeId, effectiveType, now);

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
    if (!await isOnline)
      throw Exception("Cannot upload: Check internet connection");

    final user = _client.auth.currentUser;
    debugPrint(
      "DEBUG: Uploading photo. User: ${user?.id}, Email: ${user?.email}",
    );

    if (user == null) {
      throw Exception("Unauthorized: No active session. Please log in again.");
    }

    try {
      final fileName =
          '${employeeId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final path = '$employeeId/$fileName';

      await _client.storage
          .from('employee-photos')
          .upload(
            path,
            imageFile,
            fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
          );

      final publicUrl = _client.storage
          .from('employee-photos')
          .getPublicUrl(path);
      return publicUrl;
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
      // 1. Insert Employee Record (without embedding initially, or we insert empty)
      // We reuse registerEmployee but we need a dummy embedding or change logic.
      // But registerEmployee takes an embedding.
      // Let's modify the flow: Insert employee separately first.

      final employeeResponse = await _client
          .from('employees')
          .insert(employeeData)
          .select()
          .single();

      employeeId = employeeResponse['id'] as int;

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
          await _client
              .from('employees')
              .update({'image_url': uploadedPhotoUrl})
              .eq('id', employeeId);
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

      // 4. Trigger Sync
      syncEmployees(); // Fire and forget or await? best to await if we want immediate feedback

      return employeeId;
    } catch (e) {
      debugPrint('Registration with photos failed: $e');
      if (employeeId != null) {
        try {
          await _client.from('employees').delete().eq('id', employeeId);
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

    // If local is empty, try network as fallback
    if (!await isOnline) {
      return [];
    }

    try {
      final response = await _client
          .from('employees')
          .select('id, first_name, last_name, position, image_url')
          .order('first_name', ascending: true);

      final List<Map<String, dynamic>> employees = [];

      for (final emp in response) {
        final empId = emp['id'] as int;
        String? photoUrl = emp['image_url'] as String?;

        if (photoUrl == null || photoUrl.isEmpty) {
          try {
            final files = await _client.storage
                .from('employee-photos')
                .list(
                  path: '$empId',
                  searchOptions: const SearchOptions(limit: 1),
                );

            if (files.isNotEmpty) {
              photoUrl = _client.storage
                  .from('employee-photos')
                  .getPublicUrl('$empId/${files.first.name}');
            }
          } catch (e) {
            debugPrint('Could not fetch photo for employee $empId: $e');
          }
        }

        employees.add({
          'id': empId,
          'first_name': emp['first_name'] ?? '',
          'last_name': emp['last_name'] ?? '',
          'position': emp['position'] ?? '',
          'photo_url': photoUrl,
        });
      }

      return employees;
    } catch (e) {
      debugPrint('Error fetching employees with photos: $e');
      return [];
    }
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

    // Local verification didn't confirm. If online, fall back to RPC and trigger background sync if match found.
    if (await isOnline) {
      try {
        final vectorStr = '[${normalizedEmbedding.join(',')}]';
        final response = await _client.rpc(
          'match_face',
          params: {
            'query_embedding': vectorStr,
            'match_threshold': 0.6,
            'match_count': 5,
          },
        );

        final List<dynamic> results = response;
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
