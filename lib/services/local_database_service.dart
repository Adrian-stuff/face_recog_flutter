import 'dart:convert';
import 'dart:io';
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

  /// Whether [table] exists at all. A migration that ALTERs a table which was
  /// never created would fail just as hard as adding a duplicate column.
  static Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    return rows.isNotEmpty;
  }

  /// Adds a column only if it isn't already there.
  ///
  /// SQLite has no `ADD COLUMN IF NOT EXISTS`, and every migration below used
  /// a bare ALTER. That assumes a database's recorded `user_version` always
  /// matches its actual shape — and when it doesn't, the failure is total and
  /// permanent: sqflite runs onUpgrade in a transaction, so one duplicate
  /// column rolls the whole thing back, `user_version` never advances, and the
  /// identical upgrade is retried on every single open. The database then
  /// never opens again, which takes down attendance recording, sync and the
  /// offline face cache together, since all of them go through [database].
  ///
  /// That is not hypothetical — a kiosk in the field hit exactly this and sat
  /// in the retry loop until it was patched. Checking first means a device
  /// whose schema has drifted from its version number repairs itself on the
  /// next open instead of being bricked by the mismatch.
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    if (!await _tableExists(db, table)) return;
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((c) => c['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// Every column each table is expected to have, once all migrations have
  /// run. The single source of truth that [_reconcileSchema] enforces.
  ///
  /// Primary keys and NOT NULL columns are omitted deliberately: this drives
  /// `ALTER TABLE ADD COLUMN`, which SQLite will not accept for a NOT NULL
  /// column without a default. Those only ever come from CREATE TABLE, so
  /// they cannot be missing from a table that exists at all.
  static const Map<String, Map<String, String>> _expectedColumns = {
    'employees': {
      'first_name': 'TEXT',
      'last_name': 'TEXT',
      'position': 'TEXT',
      'image_url': 'TEXT',
      'local_image_path': 'TEXT',
      'face_features': 'TEXT',
    },
    'attendance_logs': {
      'employee_id': 'INTEGER',
      'timestamp': 'TEXT',
      'type': 'TEXT',
      'is_synced': 'INTEGER DEFAULT 0',
      'sync_error': 'TEXT',
      'lat': 'REAL',
      'lng': 'REAL',
      'is_mocked': 'INTEGER',
      'wifi_ssid': 'TEXT',
      'wifi_bssid': 'TEXT',
      'client_event_id': 'TEXT',
      'app_version': 'TEXT',
    },
    'offline_encodings': {
      'employee_id': 'INTEGER',
      'descriptor': 'TEXT',
      'is_golden': 'INTEGER DEFAULT 0',
      'created_at': 'TEXT',
      'is_synced': 'INTEGER DEFAULT 0',
      'sync_error': 'TEXT',
    },
    // scan_events and error_reports were outside the reconciliation net until
    // now: five tables exist, three were declared here, so a column added to
    // either of these depended entirely on onUpgrade firing. That is the exact
    // assumption _reconcileSchema exists because it cannot be trusted — a
    // partly-applied upgrade leaves user_version unchanged and the column
    // never arrives. Only NULLable or defaulted columns belong here; ALTER
    // TABLE ADD COLUMN cannot add a NOT NULL column without a default, and
    // the PRIMARY KEY is omitted because it can only be set at CREATE time.
    'scan_events': {
      'employee_id': 'INTEGER',
      'employee_name': 'TEXT',
      'attendance_type': 'TEXT',
      'match_confidence': 'REAL',
      'liveness_passed': 'INTEGER',
      'thumbnail': 'TEXT',
      'rejection_reason': 'TEXT',
      'lat': 'REAL',
      'lng': 'REAL',
      'wifi_ssid': 'TEXT',
      'wifi_bssid': 'TEXT',
      'is_uploaded': 'INTEGER DEFAULT 0',
      'server_confirmed': 'INTEGER DEFAULT 0',
      'upload_attempts': 'INTEGER DEFAULT 0',
      'last_attempt_at': 'TEXT',
    },
    'error_reports': {
      'context': 'TEXT',
      'app_version': 'TEXT',
      'is_uploaded': 'INTEGER DEFAULT 0',
      'upload_attempts': 'INTEGER DEFAULT 0',
    },
  };

  /// The reconciliation target, exposed read-only so migration tests can
  /// check convergence against the real declared schema instead of a
  /// hand-copied duplicate that could silently drift from it.
  @visibleForTesting
  static Map<String, Map<String, String>> get expectedColumnsForTesting =>
      _expectedColumns;

  /// Columns in [expected] that [actual] doesn't have.
  ///
  /// Split out as a pure function so the reconciliation rule is unit-testable
  /// without a database engine.
  static List<MapEntry<String, String>> missingColumns(
    Set<String> actual,
    Map<String, String> expected,
  ) {
    return expected.entries.where((e) => !actual.contains(e.key)).toList();
  }

  /// Brings the real schema up to [_expectedColumns], whatever route the
  /// database took to get here.
  ///
  /// Runs on *every* open, not just on a version bump, because `user_version`
  /// has repeatedly turned out to be an unreliable description of what a
  /// device actually has. Two ways that happened here, both of which reached
  /// production:
  ///
  ///   * onCreate drifted from the cumulative onUpgrade result, so fresh
  ///     installs came up missing `client_event_id` and every attendance
  ///     write failed with "no column named client_event_id".
  ///   * an onUpgrade threw partway, and because sqflite wraps it in a
  ///     transaction the version was never advanced — so the same broken
  ///     upgrade was retried on every launch, forever, and the kiosk could
  ///     not open its database at all.
  ///
  /// Reconciling against a declared target makes both self-correcting: the
  /// device converges on the right schema on the next launch instead of
  /// needing a patch. It is also cheap — a handful of PRAGMA reads.
  static Future<void> _reconcileSchema(Database db) async {
    for (final table in _expectedColumns.entries) {
      // A table that doesn't exist isn't reconciled here; creating it is
      // onCreate's job, and inventing one would mask a real problem.
      if (!await _tableExists(db, table.key)) continue;

      final info = await db.rawQuery('PRAGMA table_info(${table.key})');
      final actual = info.map((c) => c['name'] as String).toSet();

      for (final column in missingColumns(actual, table.value)) {
        debugPrint(
          'Schema reconcile: adding missing ${table.key}.${column.key}',
        );
        await db.execute(
          'ALTER TABLE ${table.key} ADD COLUMN ${column.key} ${column.value}',
        );
      }
    }
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'face_attendance.db');

    return await openDatabase(
      path,
      version: 8,
      // A Shorebird rollback puts older code in front of a newer database.
      // sqflite's default behaviour there is to throw, which would brick the
      // kiosk exactly when someone is rolling back to *un*-brick it. The
      // schema only ever grows, so an older build simply ignores the columns
      // it doesn't know about — doing nothing is safe, and far safer than
      // onDatabaseDowngradeDelete, which would throw away every queued punch
      // that hadn't synced yet.
      onDowngrade: (db, oldVersion, newVersion) async {},
      // Last line of defence, after whichever of onCreate/onUpgrade/neither
      // ran. See _reconcileSchema: user_version has proven an unreliable
      // description of what a device actually has, so the schema is verified
      // against a declared target on every open rather than trusted.
      onOpen: _reconcileSchema,
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

        // Must stay in sync with the cumulative result of every onUpgrade
        // block below — onCreate only runs for a database that doesn't
        // exist yet, so onUpgrade's incremental ALTER TABLEs never run for
        // a fresh install. This table previously stopped at the v5 columns
        // here, so any brand-new install (not an upgrade from an older
        // version) got a table with no client_event_id at all, and every
        // attendance write crashed with "no column named client_event_id".
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
            wifi_bssid TEXT,
            client_event_id TEXT,
            app_version TEXT
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

        await db.execute(_createScanEventsSql);
        await db.execute(_scanEventsPendingIndexSql);
        await db.execute(_createErrorReportsSql);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _addColumnIfMissing(db, 'employees', 'image_url', 'TEXT');
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
          await _addColumnIfMissing(
            db, 'employees', 'local_image_path', 'TEXT',
          );
        }
        if (oldVersion < 4) {
          // Previously, a sync attempt that permanently failed (e.g. server
          // rejected an offline log as too old) was marked is_synced=1 to
          // stop retrying — indistinguishable from a real success, so the
          // failure was invisible. sync_error now records why, so failures
          // stay visible instead of silently vanishing from the queue.
          await _addColumnIfMissing(
            db, 'attendance_logs', 'sync_error', 'TEXT',
          );
          await _addColumnIfMissing(
            db, 'offline_encodings', 'sync_error', 'TEXT',
          );
        }
        if (oldVersion < 5) {
          // Server-side location enforcement (checkLocation()) never
          // actually received these — the app read them (NetworkGuard,
          // isMocked) but only used them to gate the UI locally. Persisting
          // them per-log lets a later sync still report what was true at
          // the moment of the action, not whatever the device's state is
          // when it finally gets a connection.
          await _addColumnIfMissing(db, 'attendance_logs', 'lat', 'REAL');
          await _addColumnIfMissing(db, 'attendance_logs', 'lng', 'REAL');
          await _addColumnIfMissing(
            db, 'attendance_logs', 'is_mocked', 'INTEGER',
          );
          await _addColumnIfMissing(
            db, 'attendance_logs', 'wifi_ssid', 'TEXT',
          );
          await _addColumnIfMissing(
            db, 'attendance_logs', 'wifi_bssid', 'TEXT',
          );
        }
        if (oldVersion < 6) {
          // Two halves of the same problem: proving a scan happened, and
          // being able to retry its upload safely.
          //
          // client_event_id is generated before the first upload attempt, so
          // a retry after a lost response reconciles to the original server
          // row rather than tripping the one-per-day unique constraint and
          // being recorded as a permanent failure.
          await _addColumnIfMissing(
            db, 'attendance_logs', 'client_event_id', 'TEXT',
          );
          // scan_events records every attempt, including the ones that never
          // produced an attendance row at all — previously those vanished,
          // which is exactly the case someone disputes later.
          await db.execute(_createScanEventsSql);
          await db.execute(_scanEventsPendingIndexSql);
        }
        if (oldVersion < 7) {
          // Error reports were previously fire-and-forget HTTP calls only —
          // if the device was offline (or the request otherwise failed)
          // when a crash happened, the report was simply gone, including
          // exactly the kind of crash an admin most needs to see (one that
          // broke attendance recording). Writing it here first, before any
          // network attempt, makes it durable the same way attendance logs
          // and scan events already are.
          await db.execute(_createErrorReportsSql);
        }
        if (oldVersion < 8) {
          // Stamped at punch time and carried through the offline queue, so a
          // log that syncs days later still reports the build that created
          // it rather than whatever the device happens to be running by then
          // — the two diverge every time a Shorebird patch lands.
          await _addColumnIfMissing(
            db, 'attendance_logs', 'app_version', 'TEXT',
          );
        }
      },
    );
  }

  static const String _createScanEventsSql = '''
    CREATE TABLE IF NOT EXISTS scan_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      client_event_id TEXT NOT NULL UNIQUE,
      employee_id INTEGER,
      employee_name TEXT,
      scanned_at TEXT NOT NULL,
      outcome TEXT NOT NULL,
      attendance_type TEXT,
      match_confidence REAL,
      liveness_passed INTEGER,
      thumbnail TEXT,
      rejection_reason TEXT,
      lat REAL,
      lng REAL,
      wifi_ssid TEXT,
      wifi_bssid TEXT,
      is_uploaded INTEGER DEFAULT 0,
      server_confirmed INTEGER DEFAULT 0,
      upload_attempts INTEGER DEFAULT 0,
      last_attempt_at TEXT
    )
  ''';

  // The upload loop's hot query: what still needs sending, oldest first.
  static const String _scanEventsPendingIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_scan_events_pending '
      'ON scan_events (is_uploaded, scanned_at)';

  static const String _createErrorReportsSql = '''
    CREATE TABLE IF NOT EXISTS error_reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      level TEXT NOT NULL,
      message TEXT NOT NULL,
      context TEXT,
      app_version TEXT,
      created_at TEXT NOT NULL,
      is_uploaded INTEGER DEFAULT 0,
      upload_attempts INTEGER DEFAULT 0
    )
  ''';

  // --- Synchronization Methods (Down: Supabase -> Local) ---

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

  /// Reads one face descriptor out of whatever shape the server sent it in.
  ///
  /// It is not always a JSON array. `face_encodings.descriptor` is a pgvector
  /// column, and PostgreSQL has no cast from `vector` to json, so a server
  /// building the sync payload with `json_build_object('descriptor', descriptor)`
  /// emits the vector's *text* form — the JSON string "[0.1,0.2,...]" — rather
  /// than a list. Every such entry used to be dropped on the floor here, which
  /// left this cache empty for the entire roster and quietly turned offline
  /// face verification off: with no cached vectors to score against,
  /// verifyFaceAgainstEmployee() had to reach /api/match-face for every single
  /// scan, so any loss of connectivity showed up at the kiosk as "face not
  /// recognized" for everyone. The server now sends a real array, but parsing
  /// the string form too means a kiosk keeps working against an older backend
  /// instead of silently losing its offline path again.
  static List<double>? _coerceDescriptor(dynamic raw) {
    if (raw is List) {
      if (raw.isEmpty) return null;
      final out = <double>[];
      for (final v in raw) {
        if (v is num) {
          out.add(v.toDouble());
        } else {
          // A mixed/garbage element means this isn't a usable vector at all;
          // a partial descriptor would score as a stranger's face.
          return null;
        }
      }
      return out;
    }

    if (raw is String) {
      final trimmed = raw.trim();
      if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) return null;
      final body = trimmed.substring(1, trimmed.length - 1).trim();
      if (body.isEmpty) return null;
      final out = <double>[];
      for (final part in body.split(',')) {
        final parsed = double.tryParse(part.trim());
        if (parsed == null) return null;
        out.add(parsed);
      }
      return out;
    }

    return null;
  }

  /// Number of employees currently holding at least one usable face vector.
  ///
  /// Exposed so the sync path can tell "nobody is enrolled yet" apart from
  /// "the roster arrived but nothing could be decoded" — the second is a
  /// defect and looked exactly like the first for as long as the descriptors
  /// were being double-encoded.
  int get employeesWithCachedVectors =>
      _vectorCache.values.where((v) => v.isNotEmpty).length;

  /// Replaces the local roster.
  ///
  /// Returns false without touching anything when handed an empty list while
  /// the device already holds employees. The write below deletes before it
  /// inserts, so an empty payload wipes every face vector on the device — and
  /// a kiosk that then goes offline cannot match anyone until it reconnects.
  /// A 200 carrying `[]` is indistinguishable here from a company-scoping
  /// regression, so the safe reading is to keep what we have and let the
  /// caller report it.
  Future<bool> syncEmployees(List<Map<String, dynamic>> employees) async {
    final db = await database;

    if (employees.isEmpty) {
      final existing = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM employees'),
      );
      if (existing != null && existing > 0) {
        debugPrint(
          'Refusing to replace $existing local employees with an empty sync '
          'payload; keeping the existing roster.',
        );
        return false;
      }
    }

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
          // Already a JSON string by the time it gets here — supabase_service
          // jsonEncode()s the descriptor list before handing it over. Encoding
          // it a second time produced a JSON string *containing* JSON, which
          // jsonDecode then unwrapped to a String rather than a List, so
          // _initializeVectorCache found nothing to cache and every employee
          // came back with no local face data. Online that was invisible,
          // because verification silently fell through to the server; offline
          // there is no fallback and the kiosk could not match anyone.
          'face_features': emp['face_features'] is String
              ? emp['face_features']
              : (emp['face_features'] != null
                    ? jsonEncode(emp['face_features'])
                    : null),
        });
      }
    });

    // Pre-decode and normalize vectors in-memory
    await _initializeVectorCache();

    debugPrint(
      'Synced ${employees.length} employees to local DB with pre-normalized vectors',
    );
    return true;
  }

  /// Drops every trace of the current company's roster: employee rows, the
  /// in-memory face vectors, and the cached avatar files.
  ///
  /// Called when a device turns out to be bound to a different company than
  /// the one it was set up for. Attendance logs are deliberately left alone
  /// — they are the evidence trail for work that actually happened, and
  /// destroying them to tidy up a misconfiguration would be the more
  /// damaging bug. They're marked orphaned instead (and, unlike a prior
  /// version of this method, actually flagged is_synced so they truly stop
  /// being retried — a row with only sync_error set was still picked up by
  /// getUnsyncedLogs()'s `is_synced = 0` query, contradicting the "stop
  /// being retried" this comment already promised).
  ///
  /// scan_events and error_reports get different treatment: they're not
  /// evidence tied to a person's pay, they're this device's own upload
  /// queue, and syncScanEvents()/syncPendingErrorReports() key off whatever
  /// API key is currently loaded with no per-row company tag. Left alone,
  /// any still-pending rows from the old company (thumbnails, employee
  /// names, GPS/WiFi) would upload straight into whichever company this
  /// device gets re-paired to next — a real cross-tenant leak, not just a
  /// wasted retry. They're marked as already-uploaded here (suppressed, not
  /// deleted) so the on-device history stays inspectable without ever
  /// reaching the wrong company's dashboard.
  Future<int> purgeTenantRoster() async {
    final db = await database;

    _vectorCache.clear();
    _cacheInitialized = false;

    final images = await db.query(
      'employees',
      columns: ['local_image_path'],
      where: 'local_image_path IS NOT NULL',
    );

    final removed = await db.delete('employees');

    await db.update(
      'attendance_logs',
      {
        'is_synced': 1,
        'sync_error': 'Orphaned: recorded before this device was re-paired',
      },
      where: 'is_synced = 0 AND sync_error IS NULL',
    );
    await db.update(
      'offline_encodings',
      {
        'is_synced': 1,
        'sync_error': 'Orphaned: recorded before this device was re-paired',
      },
      where: 'is_synced = 0 AND sync_error IS NULL',
    );

    final orphanedScans = await db.update(
      'scan_events',
      {
        'is_uploaded': 1,
        'rejection_reason': 'Orphaned: device was re-paired to a different company before this scan synced',
      },
      where: 'is_uploaded = 0 AND rejection_reason IS NULL',
    );
    final orphanedReports = await db.update(
      'error_reports',
      {'is_uploaded': 1},
      where: 'is_uploaded = 0',
    );

    for (final row in images) {
      final path = row['local_image_path'] as String?;
      if (path == null) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('purgeTenantRoster: failed to delete $path: $e');
      }
    }

    debugPrint(
      'purgeTenantRoster: removed $removed employees and their cached faces, '
      'suppressed $orphanedScans pending scan events and $orphanedReports '
      'pending error reports from the previous company',
    );
    return removed;
  }

  /// Initialize vector cache by decoding and normalizing all vectors
  /// Decodes a stored `employees.face_features` value into descriptor
  /// entries.
  ///
  /// Split out as a pure function for the same reason [missingColumns] was:
  /// the bug it exists to prevent is a decoding bug, and pinning it should not
  /// require standing up a database engine.
  ///
  /// Accepts three shapes, because all three have been written to this column:
  /// the JSON string supabase_service produces, the same string wrapped in a
  /// second layer of JSON (what the double-encode wrote before it was fixed),
  /// and the legacy bare-vector formats that predate golden encodings.
  @visibleForTesting
  static List<Map<String, dynamic>> parseFaceFeatures(String? featureStr) {
    if (featureStr == null || featureStr.isEmpty) return const [];

    final List<Map<String, dynamic>> entries = [];
    try {
      var decoded = jsonDecode(featureStr);

      // A row written double-encoded decodes to a String that still holds the
      // real JSON. Unwrap it rather than making every affected device wait for
      // a fresh sync to become usable — the devices worst hit are precisely
      // the ones that cannot reach the server to sync.
      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {
          return const [];
        }
      }

      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map) {
          for (final item in decoded) {
            if (item is Map) {
              final desc = _coerceDescriptor(item['descriptor']);
              if (desc != null) {
                entries.add({
                  'descriptor': desc,
                  'isGolden': item['is_golden'] == true,
                });
              }
            }
          }
        } else if (first is List || first is String) {
          // Legacy format: [[...], [...]] — all treated as non-golden.
          for (final v in decoded) {
            final desc = _coerceDescriptor(v);
            if (desc != null) {
              entries.add({'descriptor': desc, 'isGolden': false});
            }
          }
        } else if (first is num) {
          // Legacy single vector: [...].
          entries.add({
            'descriptor': List<double>.from(decoded),
            'isGolden': false,
          });
        }
      }
    } catch (_) {
      return const [];
    }
    return entries;
  }

  Future<void> _initializeVectorCache() async {
    if (_cacheInitialized) return;

    final db = await database;
    final employees = await db.query('employees');

    for (var emp in employees) {
      final empId = emp['id'] as int;
      final featureStr = emp['face_features'] as String?;

      if (featureStr == null || featureStr.isEmpty) continue;

      try {
        final entries = parseFaceFeatures(featureStr);

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

  /// A date-string window that is guaranteed to *contain* the device's local
  /// calendar day, for use as a cheap SQL pre-filter. Callers must still pass
  /// each row through [_isLocalToday]; this only narrows the scan.
  ///
  /// It deliberately over-selects by a day on each side because `timestamp`
  /// is not stored in one single format. Rows written before the UTC fix are
  /// naive local ISO strings ("2026-08-12T09:08:57.792"); rows written after
  /// it are UTC ("2026-08-12T01:08:57.792Z"). Comparing either directly
  /// against local-midnight bounds is wrong for the other, and in Manila
  /// (UTC+8) the UTC form silently falls onto the *previous* calendar date for
  /// anything punched before 08:00 local — which is exactly the window an
  /// overnight overtime session ends in. A ±1 day net covers every real
  /// timezone offset, and the precise decision happens in Dart where the
  /// offset is actually known.
  static (String, String) _todayScanWindow() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String dateKey(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    // Every stored timestamp starts with "YYYY-MM-DD", so a plain string
    // range over date prefixes is a valid superset filter in both formats.
    return (
      dateKey(today.subtract(const Duration(days: 1))),
      dateKey(today.add(const Duration(days: 2))),
    );
  }

  /// Whether a stored `timestamp` falls on the device's local calendar day.
  ///
  /// `DateTime.parse` resolves both storage formats correctly: a trailing "Z"
  /// yields a UTC instant that `toLocal()` shifts into local time, while a
  /// naive string is already parsed as local and passes through unchanged.
  static bool _isLocalToday(Object? rawTimestamp) {
    if (rawTimestamp is! String) return false;
    final parsed = DateTime.tryParse(rawTimestamp);
    if (parsed == null) return false;
    final local = parsed.toLocal();
    final now = DateTime.now();
    return local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
  }

  /// Rows with `sync_error` set were permanently rejected by the server
  /// (duplicate, location check, stale timestamp, etc.) — they never became
  /// a real punch there, so they must not count as "already recorded" here.
  /// Otherwise one rejected sync permanently locks the employee out of that
  /// action for the rest of the day, since nothing else ever clears the row.
  Future<bool> hasLogForToday(int employeeId, String type) async {
    final db = await database;
    final (windowStart, windowEnd) = _todayScanWindow();

    final result = await db.query(
      'attendance_logs',
      columns: ['timestamp'],
      where:
          'employee_id = ? AND type = ? AND timestamp >= ? AND timestamp < ? AND sync_error IS NULL',
      whereArgs: [employeeId, type, windowStart, windowEnd],
    );

    return result.any((row) => _isLocalToday(row['timestamp']));
  }

  /// How many punches of [type] this device recorded for [employeeId] today.
  ///
  /// [hasLogForToday] answers the same question as a yes/no, which is enough
  /// for time-in and time-out — there is at most one of each a day, enforced
  /// by a unique index server-side. Breaks are the exception: an employee can
  /// take several, so "are they on a break right now" is a comparison of two
  /// counts, not two booleans.
  Future<int> countLogsForToday(int employeeId, String type) async {
    final db = await database;
    final (windowStart, windowEnd) = _todayScanWindow();

    final result = await db.query(
      'attendance_logs',
      columns: ['timestamp'],
      where:
          'employee_id = ? AND type = ? AND timestamp >= ? AND timestamp < ? AND sync_error IS NULL',
      whereArgs: [employeeId, type, windowStart, windowEnd],
    );

    return result.where((row) => _isLocalToday(row['timestamp'])).length;
  }

  /// Whether this device believes [employeeId] is on a break right now.
  ///
  /// A break that was punched out of but not back into leaves one more
  /// break-out than break-in. Counting rather than comparing the newest two
  /// rows keeps this correct when a punch failed to sync and was excluded —
  /// the count simply falls, and the worst case is offering a punch the
  /// server then decides on.
  Future<bool> isOnBreakToday(int employeeId) async {
    final out = await countLogsForToday(employeeId, 'break-out');
    final back = await countLogsForToday(employeeId, 'break-in');
    return out > back;
  }

  /// Every attendance punch recorded on this device today, newest first,
  /// with the employee's name attached — what the kiosk shows an employee
  /// who wants to see who's clocked in/out so far today.
  ///
  /// Inner-joined against the current `employees` table rather than trusting
  /// `employee_id` alone: after a device is re-paired to a different
  /// company, any leftover rows from the previous tenant have no matching
  /// row here (the roster was purged — see purgeTenantRoster) and are
  /// correctly excluded instead of showing as a name-less mystery entry.
  Future<List<Map<String, dynamic>>> getTodayAttendance() async {
    final db = await database;
    final (windowStart, windowEnd) = _todayScanWindow();

    final rows = await db.rawQuery(
      '''
      SELECT
        al.id,
        al.employee_id,
        e.first_name,
        e.last_name,
        al.type,
        al.timestamp
      FROM attendance_logs al
      INNER JOIN employees e ON e.id = al.employee_id
      WHERE al.timestamp >= ? AND al.timestamp < ?
      ORDER BY al.timestamp DESC
      ''',
      [windowStart, windowEnd],
    );

    return rows.where((row) => _isLocalToday(row['timestamp'])).toList();
  }

  /// What each employee has punched today, keyed by employee id, as a map of
  /// attendance type to the timestamp it was recorded at — e.g.
  /// `{7: {'time-in': '...', 'time-out': '...'}}`. Employees with nothing
  /// today are simply absent from the result.
  ///
  /// The roster panel on the scan screen joins this against the employee
  /// list it already holds, so this deliberately returns punches only: one
  /// roster source on screen means a name can't appear in the roll call but
  /// be missing from the selector behind it.
  ///
  /// Carries the same "this device only" caveat as [getTodayAttendance] — a
  /// shift started on another kiosk isn't here, so the answer is what this
  /// device has seen rather than a company-wide roll call.
  ///
  /// Rows carrying a `sync_error` are excluded for exactly the reason
  /// [hasLogForToday] excludes them: the server refused them, so they never
  /// became a real punch and must not read as one here.
  Future<Map<int, Map<String, String>>> getTodayPunchesByEmployee() async {
    final db = await database;
    final (windowStart, windowEnd) = _todayScanWindow();

    final rows = await db.query(
      'attendance_logs',
      columns: ['employee_id', 'type', 'timestamp'],
      where: 'timestamp >= ? AND timestamp < ? AND sync_error IS NULL',
      whereArgs: [windowStart, windowEnd],
      // Ascending, so when a type somehow has two rows the earliest wins
      // below — the punch that actually opened the stretch is the one worth
      // showing a "since" time for.
      orderBy: 'timestamp ASC',
    );

    final punches = <int, Map<String, String>>{};
    for (final row in rows) {
      // The date-prefix window above is a deliberate superset; this is where
      // the device's real UTC offset decides what "today" means.
      if (!_isLocalToday(row['timestamp'])) continue;
      final employeeId = row['employee_id'];
      final type = row['type'];
      final timestamp = row['timestamp'];
      if (employeeId is! int || type is! String || timestamp is! String) {
        continue;
      }
      punches.putIfAbsent(employeeId, () => <String, String>{});
      punches[employeeId]!.putIfAbsent(type, () => timestamp);
    }

    return punches;
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
    String? clientEventId,
    String? appVersion,
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
      'client_event_id': clientEventId,
      'app_version': appVersion,
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
    String? clientEventId,
    String? appVersion,
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
      clientEventId: clientEventId,
      appVersion: appVersion,
    );
  }

  // --- Scan evidence ---

  /// Records one scan attempt, whatever came of it.
  ///
  /// Written before any network call so the evidence survives the app being
  /// killed mid-sync. [clientEventId] is shared with the attendance log for
  /// the same scan, which is what lets the server link the two and what makes
  /// "they scanned but nothing was recorded" a query rather than a guess.
  Future<void> insertScanEvent({
    required String clientEventId,
    required DateTime scannedAt,
    required String outcome,
    int? employeeId,
    String? employeeName,
    String? attendanceType,
    double? matchConfidence,
    bool? livenessPassed,
    String? thumbnail,
    String? rejectionReason,
    double? lat,
    double? lng,
    String? wifiSsid,
    String? wifiBssid,
  }) async {
    final db = await database;
    await db.insert('scan_events', {
      'client_event_id': clientEventId,
      'employee_id': employeeId,
      'employee_name': employeeName,
      'scanned_at': scannedAt.toIso8601String(),
      'outcome': outcome,
      'attendance_type': attendanceType,
      'match_confidence': matchConfidence,
      'liveness_passed': livenessPassed == null ? null : (livenessPassed ? 1 : 0),
      'thumbnail': thumbnail,
      'rejection_reason': rejectionReason,
      'lat': lat,
      'lng': lng,
      'wifi_ssid': wifiSsid,
      'wifi_bssid': wifiBssid,
      'is_uploaded': 0,
      'server_confirmed': 0,
      'upload_attempts': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Updates a scan's outcome once its attendance log's fate is known.
  Future<void> updateScanOutcome(
    String clientEventId,
    String outcome, {
    String? rejectionReason,
  }) async {
    final db = await database;
    await db.update(
      'scan_events',
      {
        'outcome': outcome,
        if (rejectionReason != null) 'rejection_reason': rejectionReason,
        // The server holds an older version of this row now, so re-upload it.
        'is_uploaded': 0,
      },
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  /// Scans still waiting to reach the server, oldest first.
  ///
  /// Skips rows already retried past [maxAttempts] so one permanently
  /// unacceptable event (corrupt payload, say) can't stall the queue behind
  /// it forever. Those stay in the table — visible in the history screen —
  /// rather than being deleted.
  Future<List<Map<String, dynamic>>> getPendingScanEvents({
    int limit = 50,
    int maxAttempts = 10,
  }) async {
    final db = await database;
    return await db.query(
      'scan_events',
      where: 'is_uploaded = 0 AND upload_attempts < ?',
      whereArgs: [maxAttempts],
      orderBy: 'scanned_at ASC',
      limit: limit,
    );
  }

  Future<void> markScanEventsUploaded(List<String> clientEventIds) async {
    if (clientEventIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(clientEventIds.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE scan_events SET is_uploaded = 1 WHERE client_event_id IN ($placeholders)',
      clientEventIds,
    );
  }

  Future<void> incrementScanUploadAttempts(List<String> clientEventIds) async {
    if (clientEventIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(clientEventIds.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE scan_events SET upload_attempts = upload_attempts + 1, '
      'last_attempt_at = ? WHERE client_event_id IN ($placeholders)',
      [DateTime.now().toIso8601String(), ...clientEventIds],
    );
  }

  // --- Error reports ---

  /// Records an error/warning before any network attempt, so it survives
  /// being offline (or the upload itself failing) instead of being lost the
  /// moment it happens.
  Future<int> insertErrorReport({
    required String level,
    required String message,
    String? context,
    String? appVersion,
  }) async {
    final db = await database;
    return db.insert('error_reports', {
      'level': level,
      'message': message,
      'context': context,
      'app_version': appVersion,
      'created_at': DateTime.now().toIso8601String(),
      'is_uploaded': 0,
      'upload_attempts': 0,
    });
  }

  /// Reports still waiting to reach the server, oldest first. Caps attempts
  /// like scan events, so one permanently-unsendable row (e.g. an
  /// oversized context blob the server rejects) can't stall the rest.
  Future<List<Map<String, dynamic>>> getPendingErrorReports({
    int limit = 50,
    int maxAttempts = 10,
  }) async {
    final db = await database;
    return db.query(
      'error_reports',
      where: 'is_uploaded = 0 AND upload_attempts < ?',
      whereArgs: [maxAttempts],
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> markErrorReportsUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE error_reports SET is_uploaded = 1 WHERE id IN ($placeholders)',
      ids,
    );
  }

  Future<void> incrementErrorReportUploadAttempts(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE error_reports SET upload_attempts = upload_attempts + 1 WHERE id IN ($placeholders)',
      ids,
    );
  }

  /// Marks which scans the server confirmed it holds an attendance record for.
  Future<void> markScansServerConfirmed(List<String> clientEventIds) async {
    if (clientEventIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(clientEventIds.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE scan_events SET server_confirmed = 1 WHERE client_event_id IN ($placeholders)',
      clientEventIds,
    );
  }

  /// Client event ids this device believes it successfully synced, for
  /// checking against what the server actually holds.
  ///
  /// `is_synced = 1` alone isn't enough: [markLogsAsFailed] also sets
  /// `is_synced = 1` (with `sync_error` set) for punches the server
  /// permanently rejected, so they stop being retried by [getUnsyncedLogs].
  /// Without excluding those here, a legitimately-rejected punch (e.g.
  /// "Already timed in") gets submitted to reconcile as if it were
  /// confirmed, comes back "missing" (it genuinely was never recorded),
  /// gets re-queued, gets rejected again for the same underlying reason,
  /// and repeats forever — the same clientEventId re-appearing in every
  /// reconciliation cycle instead of the gap actually closing.
  Future<List<String>> getSyncedClientEventIds({int limit = 200}) async {
    final db = await database;
    final rows = await db.query(
      'attendance_logs',
      columns: ['client_event_id'],
      where: 'is_synced = 1 AND sync_error IS NULL AND client_event_id IS NOT NULL',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows
        .map((r) => r['client_event_id'] as String?)
        .whereType<String>()
        .toList();
  }

  /// Re-queues logs the server turned out not to have.
  Future<int> requeueLogsByClientEventIds(List<String> clientEventIds) async {
    if (clientEventIds.isEmpty) return 0;
    final db = await database;
    final placeholders = List.filled(clientEventIds.length, '?').join(',');
    return await db.rawUpdate(
      'UPDATE attendance_logs SET is_synced = 0, '
      "sync_error = 'Server had no record on reconciliation — re-queued' "
      'WHERE client_event_id IN ($placeholders)',
      clientEventIds,
    );
  }

  /// Scan history for the admin screen, newest first.
  Future<List<Map<String, dynamic>>> getScanEvents({
    int limit = 200,
    bool unconfirmedOnly = false,
  }) async {
    final db = await database;
    return await db.query(
      'scan_events',
      // Thumbnails are several KB each; the list doesn't render them.
      columns: [
        'id',
        'client_event_id',
        'employee_id',
        'employee_name',
        'scanned_at',
        'outcome',
        'attendance_type',
        'match_confidence',
        'liveness_passed',
        'rejection_reason',
        'is_uploaded',
        'server_confirmed',
        'upload_attempts',
        'thumbnail IS NOT NULL AS has_thumbnail',
      ],
      where: unconfirmedOnly ? 'server_confirmed = 0' : null,
      orderBy: 'scanned_at DESC',
      limit: limit,
    );
  }

  Future<String?> getScanThumbnail(String clientEventId) async {
    final db = await database;
    final rows = await db.query(
      'scan_events',
      columns: ['thumbnail'],
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['thumbnail'] as String?;
  }

  /// Returns scan events that were rejected by the server since [since].
  Future<List<Map<String, dynamic>>> getRecentRejections(DateTime since) async {
    final db = await database;
    return await db.query(
      'scan_events',
      columns: [
        'client_event_id',
        'employee_name',
        'attendance_type',
        'rejection_reason',
        'scanned_at',
      ],
      where: "outcome = 'server_rejected' AND scanned_at >= ?",
      whereArgs: [since.toIso8601String()],
      orderBy: 'scanned_at DESC',
    );
  }

  /// Drops thumbnails from old, fully-settled scans.
  ///
  /// The metadata row is the audit trail and stays; only the image is
  /// reclaimed, and only once the scan is confirmed recorded and past the
  /// window in which anyone would dispute it.
  Future<int> trimOldScanThumbnails({int retentionDays = 60}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .toIso8601String();
    return await db.rawUpdate(
      'UPDATE scan_events SET thumbnail = NULL '
      'WHERE thumbnail IS NOT NULL AND server_confirmed = 1 AND scanned_at < ?',
      [cutoff],
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

  /// Raw sync columns for one attendance row, looked up by the
  /// `client_event_id` `recordAttendance()` generated for it — backs the
  /// punch-confirmation dialog's bounded wait for this specific punch's
  /// outcome (see SupabaseService.getPunchSyncState).
  Future<Map<String, dynamic>?> getLogByClientEventId(
    String clientEventId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'attendance_logs',
      columns: ['is_synced', 'sync_error'],
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
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
