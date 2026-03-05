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
      version: 3,
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
            is_synced INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE offline_encodings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employee_id INTEGER,
            descriptor TEXT,
            is_golden INTEGER DEFAULT 0,
            created_at TEXT,
            is_synced INTEGER DEFAULT 0
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
          await db.execute('ALTER TABLE employees ADD COLUMN local_image_path TEXT');
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
    
    // Clear cache before syncing
    _vectorCache.clear();
    
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
    
    debugPrint('Synced ${employees.length} employees to local DB with pre-normalized vectors');
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
        final List<List<double>> vectors = [];
        
        if (decoded is List) {
          if (decoded.isNotEmpty && decoded.first is List) {
            // Multiple vectors: [[...], [...], ...]
            for (var v in decoded) {
              if (v is List && v.isNotEmpty) {
                vectors.add(List<double>.from(v));
              }
            }
          } else if (decoded.isNotEmpty && decoded.first is num) {
            // Single vector: [...]
            vectors.add(List<double>.from(decoded));
          }
        }
        
        // Pre-normalize all vectors
        _vectorCache[empId] = vectors.map((v) {
          final normalized = _normalizeVectorInPlace(v);
          final norm = _normalizeVector(v);
          return {
            'vector': normalized,
            'norm': norm,
          };
        }).toList();
        
        debugPrint('Cached ${vectors.length} normalized vectors for employee $empId');
      } catch (e) {
        debugPrint('Error caching vectors for employee $empId: $e');
      }
    }
    
    _cacheInitialized = true;
  }

  Future<void> updateEmployeeLocalImagePath(int employeeId, String localPath) async {
    final db = await database;
    await db.update(
      'employees',
      {'local_image_path': localPath},
      where: 'id = ?',
      whereArgs: [employeeId],
    );
  }

  // --- Offline Verification Methods ---

  /// Get cached normalized vectors for an employee (O(1) lookup)
  Future<List<List<double>>> getCachedVectorsForEmployee(int employeeId) async {
    if (!_cacheInitialized) await _initializeVectorCache();
    
    final cached = _vectorCache[employeeId];
    if (cached != null) {
      return cached.map((item) => item['vector'] as List<double>).toList();
    }
    return [];
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
    });
    debugPrint(
      '${isSynced ? "Online" : "Offline"} log saved for Employee $employeeId ($type)',
    );
  }

  Future<void> insertOfflineLog(
    int employeeId,
    String type,
    DateTime timestamp,
  ) async {
    await insertLog(employeeId, type, timestamp, isSynced: false);
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
          {'is_synced': 1},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
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
          {'is_synced': 1},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }
}
