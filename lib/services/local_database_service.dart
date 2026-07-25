import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDatabaseService {
  static final LocalDatabaseService _instance =
      LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  Database? _database;

  // In-memory caches for pre-decoded and pre-normalized vectors
  // Maps employeeId -> List of {vector, norm, isGolden}
  final Map<int, List<Map<String, dynamic>>> _vectorCache = {};
  bool _cacheInitialized = false;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'face_attendance.db');

    return await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE employees (
            id INTEGER PRIMARY KEY,
            first_name TEXT,
            last_name TEXT,
            position TEXT,
            image_url TEXT,
            local_image_path TEXT,
            face_features TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE attendance_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employee_id INTEGER,
            timestamp TEXT,
            type TEXT,
            is_synced INTEGER DEFAULT 0,
            sync_error TEXT,
            lat REAL,
            lng REAL,
            is_mocked INTEGER,
            wifi_ssid TEXT,
            wifi_bssid TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE offline_encodings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employee_id INTEGER,
            descriptor TEXT,
            is_golden INTEGER DEFAULT 0,
            created_at TEXT,
            is_synced INTEGER DEFAULT 0,
            sync_error TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE employees ADD COLUMN image_url TEXT');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS offline_encodings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              employee_id INTEGER,
              descriptor TEXT,
              is_golden INTEGER DEFAULT 0,
              created_at TEXT,
              is_synced INTEGER DEFAULT 0
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE employees ADD COLUMN local_image_path TEXT',
          );
        }
        if (oldVersion < 4) {
          // Previously, a sync attempt that permanently failed (e.g. server
          // rejected an offline log as too old) was marked is_synced=1 to
          // stop retrying — indistinguishable from a real success, so the
          // failure was invisible. sync_error now records why, so failures
          // stay visible instead of silently vanishing from the queue.
          await db.execute(
            'ALTER TABLE attendance_logs ADD COLUMN sync_error TEXT',
          );
          await db.execute(
            'ALTER TABLE offline_encodings ADD COLUMN sync_error TEXT',
          );
        }
        if (oldVersion < 5) {
          // Server-side location enforcement (checkLocation()) never
          // actually received these — the app read them (NetworkGuard,
          // isMocked) but only used them to gate the UI locally. Persisting
          // them per-log lets a later sync still report what was true at
          // the moment of the action, not whatever the device's state is
          // when it finally gets a connection.
          await db.execute('ALTER TABLE attendance_logs ADD COLUMN lat REAL');
          await db.execute('ALTER TABLE attendance_logs ADD COLUMN lng REAL');
          await db.execute(
            'ALTER TABLE attendance_logs ADD COLUMN is_mocked INTEGER',
          );
          await db.execute(
            'ALTER TABLE attendance_logs ADD COLUMN wifi_ssid TEXT',
          );
          await db.execute(
            'ALTER TABLE attendance_logs ADD COLUMN wifi_bssid TEXT',
          );
        }
      },
    );
  }

  // --- Synchronization Methods (Down: Supabase -> Local) ---

  /// Pre-decode and normalize vectors for fast comparison
  static List<double>? _decodeVector(String? featureStr) {
    if (featureStr == null || featureStr.isEmpty) return null;

    try {
      final decoded = jsonDecode(featureStr);
      if (decoded is List) {
        return List<double>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// Pre-normalize a vector for O(1) cosine similarity (dot product only)
  static double _normalizeVector(List<double> vector) {
    double sum = 0;
    for (var x in vector) {
      sum += x * x;
    }
    return sqrt(sum);
  }

  /// Normalize vector in-place and return its norm
  static List<double> _normalizeVectorInPlace(List<double> vector) {
    final norm = _normalizeVector(vector);
    if (norm < 1e-10) return vector;
    return vector.map((x) => x / norm).toList();
  }

  Future<void> syncEmployees(List<Map<String, dynamic>> employees) async {
    final db = await database;

    // Clear cache before syncing. _cacheInitialized must be reset too —
    // _initializeVectorCache() is a "run once" guard, so without this the
    // rebuild below silently no-ops on every sync after the first one,
    // leaving the cache permanently empty for newly-synced employees (e.g.
    // one just registered) and pushing verification onto the online RPC
    // fallback, which only knows about production data.
    _vectorCache.clear();
    _cacheInitialized = false;

    await db.transaction((txn) async {
      await txn.delete('employees');
      for (var emp in employees) {
        await txn.insert('employees', {
          'id': emp['id'],
          'first_name': emp['first_name'],
          'last_name': emp['last_name'],
          'position': emp['position'],
          'image_url': emp['image_url'],
          'face_features': emp['face_features'] != null
              ? jsonEncode(emp['face_features'])
              : null,
        });
      }
    });

    // Pre-decode and normalize vectors in-memory
    await _initializeVectorCache();

    debugPrint(
      'Synced ${employees.length} employees to local DB with pre-normalized vectors',
    );
  }

  /// Initialize vector cache by decoding and normalizing all vectors
  Future<void> _initializeVectorCache() async {
    if (_cacheInitialized) return;

    final db = await database;
    final employees = await db.query('employees');

    for (var emp in employees) {
      final empId = emp['id'] as int;
      final featureStr = emp['face_features'] as String?;

      if (featureStr == null || featureStr.isEmpty) continue;

      try {
        final decoded = jsonDecode(featureStr);
        final List<Map<String, dynamic>> entries = [];

        if (decoded is List && decoded.isNotEmpty) {
          final first = decoded.first;
          if (first is Map) {
            // New enriched format: [{"descriptor": [...], "is_golden": true}, ...]
            for (var item in decoded) {
              if (item is Map) {
                final desc = item['descriptor'];
                final isGolden = item['is_golden'] == true;
                if (desc is List && desc.isNotEmpty) {
                  entries.add({
                    'descriptor': List<double>.from(desc),
                    'isGolden': isGolden,
                  });
                }
              }
            }
          } else if (first is List) {
            // Legacy format: [[...], [...], ...] — treat all as non-golden
            for (var v in decoded) {
              if (v is List && v.isNotEmpty) {
                entries.add({
                  'descriptor': List<double>.from(v),
                  'isGolden': false,
                });
              }
            }
          } else if (first is num) {
            // Legacy single vector: [...] — treat as non-golden
            entries.add({
              'descriptor': List<double>.from(decoded),
              'isGolden': false,
            });
          }
        }

        // Pre-normalize all vectors and store with isGolden
        _vectorCache[empId] = entries.map((e) {
          final vec = e['descriptor'] as List<double>;
          final normalized = _normalizeVectorInPlace(vec);
          return {'vector': normalized, 'isGolden': e['isGolden'] as bool};
        }).toList();

        final goldenCount = _vectorCache[empId]!
            .where((e) => e['isGolden'] == true)
            .length;
        debugPrint(
          'Cached ${entries.length} vectors for employee $empId ($goldenCount golden)',
        );
      } catch (e) {
        debugPrint('Error caching vectors for employee $empId: $e');
      }
    }

    _cacheInitialized = true;
  }

  Future<void> updateEmployeeLocalImagePath(
    int employeeId,
    String localPath,
  ) async {
    final db = await database;
    await db.update(
      'employees',
      {'local_image_path': localPath},
      where: 'id = ?',
      whereArgs: [employeeId],
    );
  }

  // --- Offline Verification Methods ---

  /// Get cached normalized vector entries for an employee, including isGolden flag.
  /// Returns a list of maps with keys 'vector' (List<double>) and 'isGolden' (bool).
  Future<List<Map<String, dynamic>>> getCachedVectorEntriesForEmployee(
    int employeeId,
  ) async {
    if (!_cacheInitialized) await _initializeVectorCache();
    return _vectorCache[employeeId] ?? [];
  }

  /// Get cached normalized vectors for an employee (O(1) lookup).
  /// Legacy convenience wrapper — does not include isGolden metadata.
  Future<List<List<double>>> getCachedVectorsForEmployee(int employeeId) async {
    final entries = await getCachedVectorEntriesForEmployee(employeeId);
    return entries.map((e) => e['vector'] as List<double>).toList();
  }

  Future<List<Map<String, dynamic>>> getAllEmployees() async {
    final db = await database;
    final result = await db.query('employees');

    // Ensure cache is initialized
    if (!_cacheInitialized) {
      await _initializeVectorCache();
    }

    return result;
  }

  Future<Map<String, dynamic>?> getEmployee(int id) async {
    final db = await database;
    final results = await db.query(
      'employees',
      where: 'id = ?',
      whereArgs: [id],
    );

    // Ensure cache is initialized
    if (!_cacheInitialized) {
      await _initializeVectorCache();
    }

    return results.isNotEmpty ? results.first : null;
  }

  // --- Offline Attendance Methods ---

  Future<bool> hasLogForToday(int employeeId, String type) async {
    final db = await database;
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day).toIso8601String();
    final endOfDay = DateTime(
      now.year,
      now.month,
      now.day,
      23,
      59,
      59,
    ).toIso8601String();

    final result = await db.query(
      'attendance_logs',
      where: 'employee_id = ? AND type = ? AND timestamp BETWEEN ? AND ?',
      whereArgs: [employeeId, type, startOfDay, endOfDay],
    );

    return result.isNotEmpty;
  }

  Future<void> insertLog(
    int employeeId,
    String type,
    DateTime timestamp, {
    bool isSynced = false,
    double? lat,
    double? lng,
    bool? isMocked,
    String? wifiSsid,
    String? wifiBssid,
  }) async {
    if (await hasLogForToday(employeeId, type)) {
      throw Exception("Already recorded on this device today ($type)");
    }

    final db = await database;
    await db.insert('attendance_logs', {
      'employee_id': employeeId,
      'type': type,
      'timestamp': timestamp.toIso8601String(),
      'is_synced': isSynced ? 1 : 0,
      'lat': lat,
      'lng': lng,
      'is_mocked': isMocked == null ? null : (isMocked ? 1 : 0),
      'wifi_ssid': wifiSsid,
      'wifi_bssid': wifiBssid,
    });
    debugPrint(
      '${isSynced ? "Online" : "Offline"} log saved for Employee $employeeId ($type)',
    );
  }

  Future<void> insertOfflineLog(
    int employeeId,
    String type,
    DateTime timestamp, {
    double? lat,
    double? lng,
    bool? isMocked,
    String? wifiSsid,
    String? wifiBssid,
  }) async {
    await insertLog(
      employeeId,
      type,
      timestamp,
      isSynced: false,
      lat: lat,
      lng: lng,
      isMocked: isMocked,
      wifiSsid: wifiSsid,
      wifiBssid: wifiBssid,
    );
  }

  // --- Synchronization Methods (Up: Local -> Supabase) ---

  Future<List<Map<String, dynamic>>> getUnsyncedLogs() async {
    final db = await database;
    return await db.query(
      'attendance_logs',
      where: 'is_synced = ?',
      whereArgs: [0],
    );
  }

  Future<void> markLogsAsSynced(List<int> logIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var id in logIds) {
        await txn.update(
          'attendance_logs',
          {'is_synced': 1, 'sync_error': null},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  /// Stops retrying a log the server has permanently rejected (e.g. too old
  /// to sync, or a genuine conflict) — but unlike [markLogsAsSynced], keeps
  /// [reason] on the row so the failure stays visible instead of looking
  /// identical to a real success.
  Future<void> markLogsAsFailed(List<int> logIds, String reason) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var id in logIds) {
        await txn.update(
          'attendance_logs',
          {'is_synced': 1, 'sync_error': reason},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> getFailedLogs() async {
    final db = await database;
    return await db.query(
      'attendance_logs',
      where: 'sync_error IS NOT NULL',
      orderBy: 'timestamp DESC',
    );
  }

  Future<int> getPendingLogsCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM attendance_logs WHERE is_synced = 0',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Dismisses one failed log (e.g. a duplicate "Already timed in" rejection)
  /// from the sync issues list. The real attendance record already exists
  /// server-side; this just removes the noisy local copy.
  Future<void> clearFailedLog(int id) async {
    final db = await database;
    await db.delete(
      'attendance_logs',
      where: 'id = ? AND sync_error IS NOT NULL',
      whereArgs: [id],
    );
  }

  Future<void> clearFailedLogs() async {
    final db = await database;
    await db.delete('attendance_logs', where: 'sync_error IS NOT NULL');
  }

  // --- Offline Encodings Methods ---

  Future<void> insertOfflineEncoding(
    int employeeId,
    List<double> descriptor, {
    bool isGolden = false,
  }) async {
    final db = await database;
    await db.insert('offline_encodings', {
      'employee_id': employeeId,
      'descriptor': jsonEncode(descriptor),
      'is_golden': isGolden ? 1 : 0,
      'created_at': DateTime.now().toIso8601String(),
      'is_synced': 0,
    });
    debugPrint('Saved offline encoding for Employee $employeeId');
  }

  Future<List<Map<String, dynamic>>> getUnsyncedEncodings() async {
    final db = await database;
    return await db.query(
      'offline_encodings',
      where: 'is_synced = ?',
      whereArgs: [0],
    );
  }

  Future<void> markEncodingsAsSynced(List<int> ids) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var id in ids) {
        await txn.update(
          'offline_encodings',
          {'is_synced': 1, 'sync_error': null},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  /// See [markLogsAsFailed] — same "stop retrying, keep the reason visible"
  /// treatment for offline face encodings.
  Future<void> markEncodingsAsFailed(List<int> ids, String reason) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var id in ids) {
        await txn.update(
          'offline_encodings',
          {'is_synced': 1, 'sync_error': reason},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> getFailedEncodings() async {
    final db = await database;
    return await db.query(
      'offline_encodings',
      where: 'sync_error IS NOT NULL',
      orderBy: 'created_at DESC',
    );
  }

  /// See [clearFailedLog] — same dismissal for a failed face encoding.
  Future<void> clearFailedEncoding(int id) async {
    final db = await database;
    await db.delete(
      'offline_encodings',
      where: 'id = ? AND sync_error IS NOT NULL',
      whereArgs: [id],
    );
  }

  Future<void> clearFailedEncodings() async {
    final db = await database;
    await db.delete('offline_encodings', where: 'sync_error IS NOT NULL');
  }

  Future<int> getPendingEncodingsCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM offline_encodings WHERE is_synced = 0',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
