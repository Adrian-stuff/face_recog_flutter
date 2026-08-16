import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/services/local_database_service.dart';

/// Checks that [LocalDatabaseService]'s schema reconciliation actually
/// converges every historical device state to the current schema — the bug
/// class described in [LocalDatabaseService]'s own doc comments: a device's
/// recorded `user_version` disagreeing with what columns it actually has.
///
/// [local_db_schema_test.dart] already unit-tests [LocalDatabaseService.missingColumns]
/// in isolation. This file drives that same real production function against
/// a historical schema snapshot for every version the app has ever shipped,
/// checked against the real, live [LocalDatabaseService.expectedColumnsForTesting]
/// target rather than a copy — so a future change to the declared schema
/// that isn't matched by an actual migration shows up here.
///
/// Deliberately pure Dart — no `sqflite_common_ffi` / real SQLite engine.
/// That means this cannot catch a genuine SQL syntax error in an `onCreate`
/// or `onUpgrade` block (those still need manual verification against a real
/// device or emulator before a release, same as before this file existed).
/// What it does guarantee: for every historical version, the columns that
/// version already has plus the columns [missingColumns] says to add cover
/// the full current schema — and a column that's already present (the field
/// incident this whole mechanism exists to prevent) is never flagged again.
void main() {
  // What a real device recorded at each `user_version` actually has —
  // transcribed from the `if (oldVersion < N)` blocks in
  // LocalDatabaseService's onUpgrade. Update this alongside any new
  // onUpgrade block; it's what makes a future gap between "what a version
  // number claims" and "what a version number actually shipped" visible
  // here instead of only on a device in the field.
  const historicalSchema = <int, Map<String, Set<String>>>{
    1: {
      'employees': {'id', 'first_name', 'last_name', 'position', 'face_features'},
      'attendance_logs': {'id', 'employee_id', 'timestamp', 'type', 'is_synced'},
    },
    2: {
      'employees': {
        'id', 'first_name', 'last_name', 'position', 'face_features', 'image_url',
      },
      'attendance_logs': {'id', 'employee_id', 'timestamp', 'type', 'is_synced'},
      'offline_encodings': {
        'id', 'employee_id', 'descriptor', 'is_golden', 'created_at', 'is_synced',
      },
    },
    3: {
      'employees': {
        'id', 'first_name', 'last_name', 'position', 'face_features',
        'image_url', 'local_image_path',
      },
      'attendance_logs': {'id', 'employee_id', 'timestamp', 'type', 'is_synced'},
      'offline_encodings': {
        'id', 'employee_id', 'descriptor', 'is_golden', 'created_at', 'is_synced',
      },
    },
    4: {
      'employees': {
        'id', 'first_name', 'last_name', 'position', 'face_features',
        'image_url', 'local_image_path',
      },
      'attendance_logs': {
        'id', 'employee_id', 'timestamp', 'type', 'is_synced', 'sync_error',
      },
      'offline_encodings': {
        'id', 'employee_id', 'descriptor', 'is_golden', 'created_at',
        'is_synced', 'sync_error',
      },
    },
    5: {
      'employees': {
        'id', 'first_name', 'last_name', 'position', 'face_features',
        'image_url', 'local_image_path',
      },
      'attendance_logs': {
        'id', 'employee_id', 'timestamp', 'type', 'is_synced', 'sync_error',
        'lat', 'lng', 'is_mocked', 'wifi_ssid', 'wifi_bssid',
      },
      'offline_encodings': {
        'id', 'employee_id', 'descriptor', 'is_golden', 'created_at',
        'is_synced', 'sync_error',
      },
    },
    6: {
      'employees': {
        'id', 'first_name', 'last_name', 'position', 'face_features',
        'image_url', 'local_image_path',
      },
      'attendance_logs': {
        'id', 'employee_id', 'timestamp', 'type', 'is_synced', 'sync_error',
        'lat', 'lng', 'is_mocked', 'wifi_ssid', 'wifi_bssid', 'client_event_id',
      },
      'offline_encodings': {
        'id', 'employee_id', 'descriptor', 'is_golden', 'created_at',
        'is_synced', 'sync_error',
      },
      // scan_events also exists from here, but it's a table CREATE (not a
      // column reconciliation), so it's out of scope for missingColumns —
      // see the note in the group below.
    },
    7: {
      'employees': {
        'id', 'first_name', 'last_name', 'position', 'face_features',
        'image_url', 'local_image_path',
      },
      'attendance_logs': {
        'id', 'employee_id', 'timestamp', 'type', 'is_synced', 'sync_error',
        'lat', 'lng', 'is_mocked', 'wifi_ssid', 'wifi_bssid', 'client_event_id',
      },
      'offline_encodings': {
        'id', 'employee_id', 'descriptor', 'is_golden', 'created_at',
        'is_synced', 'sync_error',
      },
      // error_reports also exists from here — same table-vs-column note.
    },
  };

  group('reconciling every historical version reaches the current schema', () {
    final expected = LocalDatabaseService.expectedColumnsForTesting;

    for (final entry in historicalSchema.entries) {
      final version = entry.key;
      final actualByTable = entry.value;

      test('v$version: applying the reported missing columns closes every gap', () {
        for (final table in actualByTable.keys) {
          final missing = LocalDatabaseService.missingColumns(
            actualByTable[table]!,
            expected[table]!,
          );
          final afterMigration = {
            ...actualByTable[table]!,
            ...missing.map((e) => e.key),
          };
          // _expectedColumns deliberately omits the primary key ('id') — it
          // can only ever come from CREATE TABLE, never from an ALTER — so
          // it has to be added back in before comparing against the full
          // real-world column set.
          expect(
            afterMigration,
            {'id', ...expected[table]!.keys},
            reason:
                '$table at v$version: adding what missingColumns() reports '
                'should reach exactly the declared schema, no more, no less',
          );
        }
      });
    }
  });

  test(
    'a column already present despite an older recorded version is never '
    're-added (the v5+client_event_id field incident)',
    () {
      final driftedV5AttendanceLogs = {
        ...historicalSchema[5]!['attendance_logs']!,
        'client_event_id', // present early, though v5 shouldn't have it yet
      };

      final missing = LocalDatabaseService.missingColumns(
        driftedV5AttendanceLogs,
        LocalDatabaseService.expectedColumnsForTesting['attendance_logs']!,
      );

      expect(
        missing.map((e) => e.key),
        isNot(contains('client_event_id')),
        reason: 're-adding an existing column is exactly what threw and '
            'bricked the device in the original incident',
      );
      expect(
        missing.map((e) => e.key),
        containsAll(['app_version']),
        reason: 'the genuinely missing v8 column must still be reported',
      );
    },
  );

  test(
    'every table declared in the current schema has a covering historical '
    'entry to reconcile from',
    () {
      // Guards the test data itself: a table added to _expectedColumns
      // without a matching historicalSchema entry would make the group
      // above silently skip checking it.
      final expected = LocalDatabaseService.expectedColumnsForTesting;
      final coveredTables = historicalSchema.values
          .expand((byTable) => byTable.keys)
          .toSet();
      expect(coveredTables, containsAll(expected.keys));
    },
  );
}
