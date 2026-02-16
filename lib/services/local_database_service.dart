import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDatabaseService {
  static final LocalDatabaseService _instance =
      LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  Database? _database;

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
      version: 1,
      onCreate: (db, version) async {
        // Table for caching employees and their face embeddings
        await db.execute('''
          CREATE TABLE employees (
            id INTEGER PRIMARY KEY,
            first_name TEXT,
            last_name TEXT,
            position TEXT,
            face_features TEXT
          )
        ''');

        // Table for storing offline attendance logs
        await db.execute('''
          CREATE TABLE attendance_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employee_id INTEGER,
            timestamp TEXT,
            type TEXT,
            is_synced INTEGER DEFAULT 0
          )
        ''');
      },
    );
  }

  // --- Synchronization Methods (Down: Supabase -> Local) ---

  /// Clear all employees and replace with fresh data from Supabase
  Future<void> syncEmployees(List<Map<String, dynamic>> employees) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('employees');
      for (var emp in employees) {
        await txn.insert('employees', {
          'id': emp['id'],
          'first_name': emp['first_name'],
          'last_name': emp['last_name'],
          'position': emp['position'],
          // Store face_features as JSON string if available, else null
          'face_features': emp['face_features'] != null
              ? jsonEncode(emp['face_features'])
              : null,
        });
      }
    });
    debugPrint('Synced ${employees.length} employees to local DB');
  }

  // --- Offline Verification Methods ---

  Future<List<Map<String, dynamic>>> getAllEmployees() async {
    final db = await database;
    return await db.query('employees');
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
}
