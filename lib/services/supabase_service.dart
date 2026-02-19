import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

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

  /// Check internet connectivity
  Future<bool> get isOnline async {
    final connectivityResult = await Connectivity().checkConnectivity();
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

      // Transform data for local storage
      final List<Map<String, dynamic>> localData = employees.map((e) {
        // The API returns 'face_features' as a direct list of descriptors (arrays)
        // e.g. [[0.1, ...], [0.2, ...]] or an empty array
        final features = e['face_features'];

        String? descriptorStr;
        if (features != null && features is List && features.isNotEmpty) {
          descriptorStr = jsonEncode(features);
        }

        return {
          'id': e['id'],
          'first_name': e['first_name'],
          'last_name': e['last_name'],
          'position': e['position'],
          'face_features': descriptorStr,
        };
      }).toList();

      await _localDb.syncEmployees(localData);
    } catch (e) {
      debugPrint('Sync Error: $e');
    }
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
          }),
        );

        if (response.statusCode == 200) {
          // Mark as synced only if successful
          await _localDb.markLogsAsSynced([log['id'] as int]);
        } else {
          debugPrint('Failed to sync log ${log['id']}: ${response.body}');
        }
      } catch (e) {
        debugPrint('Failed to sync log ${log['id']}: $e');
      }
    }
  }

  // --- Core Features ---

  Future<void> saveFaceDescriptor(
    int employeeId,
    List<double> embedding, {
    bool isGolden = false,
  }) async {
    if (!await isOnline) {
      throw Exception("Cannot update dataset while offline");
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
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> verifyFace(List<double> embedding) async {
    if (await isOnline) {
      // ONLINE: Use pgvector RPC
      try {
        final vectorStr = '[${embedding.join(',')}]';
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
        return {
          'id': match['employee_id'],
          'first_name': match['first_name'],
          'last_name': match['last_name'],
          'position': match['position'],
          'similarity': match['similarity'],
        };
      } catch (e) {
        debugPrint('Online verification failed: $e');
        // Fallback to offline if RPC fails
      }
    }

    // OFFLINE: Local Cosine Similarity
    debugPrint('Using Offline Verification...');
    final employees = await _localDb.getAllEmployees();
    double maxScore = -1.0;
    Map<String, dynamic>? bestMatch;

    for (var emp in employees) {
      final featureStr = emp['face_features'] as String?;
      if (featureStr == null) continue;

      List<List<double>> candidateVectors = [];

      try {
        // Try parsing as List<List<double>> (New Format)
        final decoded = jsonDecode(featureStr);
        if (decoded is List) {
          if (decoded.isNotEmpty && decoded.first is List) {
            // It's [[...], [...]]
            candidateVectors = (decoded as List)
                .map((e) => List<double>.from(e))
                .toList();
          } else {
            // Fallback: It might be a single list [0.1, ...] (Old Format or single vector)
            // But wait, our sync logic now enforces List<List>.
            // However, let's be safe. If it's a simple list of numbers, wrap it.
            candidateVectors = [List<double>.from(decoded)];
          }
        }
      } catch (e) {
        // Fallback: maybe it's the old raw string format "[0.1, ...]"
        // Try parsing manually
        try {
          final vectorList = featureStr
              .replaceAll('[', '')
              .replaceAll(']', '')
              .split(',')
              .map((e) => double.tryParse(e.trim()) ?? 0.0)
              .toList();
          candidateVectors = [vectorList];
        } catch (_) {
          continue;
        }
      }

      // Check ALL candidate vectors for this employee
      for (final vectorList in candidateVectors) {
        if (vectorList.length != embedding.length) continue;

        // Calculate Cosine Similarity
        double dotProduct = 0.0;
        double normA = 0.0;
        double normB = 0.0;

        for (int i = 0; i < embedding.length; i++) {
          dotProduct += embedding[i] * vectorList[i];
          normA += embedding[i] * embedding[i];
          normB += vectorList[i] * vectorList[i];
        }

        final score = dotProduct / (sqrt(normA) * sqrt(normB));

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
    // 1. Check local cache (prevents duplicate requests from this device)
    if (await _localDb.hasLogForToday(employeeId, type)) {
      throw Exception("Attendance already recorded today ($type)");
    }

    final now = DateTime.now();
    final timeStr =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";

    if (await isOnline) {
      try {
        final url = Uri.parse('${AppConfig.nextJsBaseUrl}/api/attendance/log');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': AppConfig.mobileApiKey,
          },
          body: jsonEncode({
            'employeeId': employeeId,
            'type': type,
            'time': timeStr,
          }),
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          // Success - Cache locally so we don't allow duplicates on this device
          await _localDb.insertLog(employeeId, type, now, isSynced: true);
          return;
        } else if (response.statusCode >= 400 && response.statusCode < 500) {
          // Client Error (e.g., 400 Bad Request, 404 Not Found)
          // Do NOT fallback to offline. Throw error immediately.
          final errorData = jsonDecode(response.body);
          throw Exception(
            errorData['error'] ?? 'Request failed: ${response.statusCode}',
          );
        } else {
          // Server Error (5xx)
          // Fallback to offline
          throw HttpException('Server Error: ${response.statusCode}');
        }
      } catch (e) {
        // If it's a specific logic error (4xx handled above), rethrow it.
        // We detect this by checking if it's NOT a network/server type error.
        // However, since we throw generic Exception for 4xx above, we need to be careful.
        // Let's refine:

        if (e.toString().contains('Request failed') ||
            e.toString().contains('already recorded') ||
            e.toString().contains('Shift not found')) {
          rethrow;
        }

        debugPrint(
          'Online attendance failed (Network/Server), falling back to offline: $e',
        );
        await _localDb.insertOfflineLog(employeeId, type, now);
      }
    } else {
      await _localDb.insertOfflineLog(employeeId, type, now);
    }
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
      try {
        await uploadEmployeePhoto(employeeId, File(photoPaths.first));
      } catch (e) {
        debugPrint("Warning: Failed to upload profile picture: $e");
        // Non-fatal? Maybe. But we want a profile pic.
      }

      // 3. Process All Photos -> Generate Embeddings -> Save as Golden
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
}
