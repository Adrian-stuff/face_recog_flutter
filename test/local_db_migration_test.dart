import 'dart:io';

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
      // scan_events exists from v6. Now that it is declared in
      // _expectedColumns it has to be described here too, or the
      // reconciliation group above would skip the very table that spent its
      // whole life outside the safety net.
      'scan_events': {
        'id', 'client_event_id', 'employee_id', 'employee_name', 'scanned_at',
        'outcome', 'attendance_type', 'match_confidence', 'liveness_passed',
        'thumbnail', 'rejection_reason', 'lat', 'lng', 'wifi_ssid',
        'wifi_bssid', 'is_uploaded', 'server_confirmed', 'upload_attempts',
        'last_attempt_at',
      },
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
      // scan_events exists from v6. Now that it is declared in
      // _expectedColumns it has to be described here too, or the
      // reconciliation group above would skip the very table that spent its
      // whole life outside the safety net.
      'scan_events': {
        'id', 'client_event_id', 'employee_id', 'employee_name', 'scanned_at',
        'outcome', 'attendance_type', 'match_confidence', 'liveness_passed',
        'thumbnail', 'rejection_reason', 'lat', 'lng', 'wifi_ssid',
        'wifi_bssid', 'is_uploaded', 'server_confirmed', 'upload_attempts',
        'last_attempt_at',
      },
      'error_reports': {
        'id', 'level', 'message', 'context', 'app_version', 'created_at',
        'is_uploaded', 'upload_attempts',
      },
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
          // Two things matter, and they are asserted separately because
          // "no more, no less" was too strong once scan_events and
          // error_reports joined the declared set.
          //
          // _expectedColumns holds only what ALTER TABLE can actually add.
          // That excludes the primary key, and it also excludes NOT NULL
          // columns with no default — `outcome`, `scanned_at`, `level`,
          // `message` and friends exist from CREATE TABLE and can never be
          // back-filled onto an existing table. A device missing those has a
          // table that was never created properly, which reconciliation
          // cannot and should not paper over.
          //
          // So: reconciliation must close every declared gap, and must not
          // invent anything that was not declared.
          expect(
            afterMigration,
            containsAll(expected[table]!.keys),
            reason:
                '$table at v$version: reconciliation should reach every '
                'declared column',
          );
          expect(
            missing.map((e) => e.key).toSet().difference(
                  expected[table]!.keys.toSet(),
                ),
            isEmpty,
            reason:
                '$table at v$version: reconciliation added a column that is '
                'not in the declared schema',
          );
        }
      });
    }
  });

  /// The schema may only ever grow.
  ///
  /// Everything that makes a Shorebird rollback survivable rests on this: the
  /// no-op onDowngrade is safe *because* older code meeting a newer database
  /// simply ignores columns it does not know about. Rename or drop one and
  /// that stops being true — the rolled-back build starts querying a column
  /// that no longer exists, on a device with unsynced punches on it, and
  /// there is no push-time check anywhere that would have caught it.
  ///
  /// historicalSchema is the record of every column this app has ever had.
  /// This asserts none of them has gone missing from the DDL.
  test('never drops or renames a column that has ever shipped', () {
    final source = File(
      'lib/services/local_database_service.dart',
    ).readAsStringSync();

    /// Column names inside each CREATE TABLE block in the real DDL.
    final currentByTable = <String, Set<String>>{};
    for (final match in RegExp(
      r'CREATE TABLE (?:IF NOT EXISTS )?(\w+)\s*\(([^;]*?)\)\s*(?:;|\x27)',
      dotAll: true,
    ).allMatches(source)) {
      final table = match.group(1)!;
      final body = match.group(2)!;
      final columns = body
          .split(',')
          .map((line) => line.trim().split(RegExp(r'\s+')).first)
          .where((name) => RegExp(r'^[a-z_]+$').hasMatch(name))
          .toSet();
      currentByTable.putIfAbsent(table, () => <String>{}).addAll(columns);
    }

    expect(currentByTable.keys, isNotEmpty, reason: 'no DDL parsed');

    for (final version in historicalSchema.entries) {
      for (final table in version.value.entries) {
        final current = currentByTable[table.key];
        expect(
          current,
          isNotNull,
          reason: 'table ${table.key} existed at v${version.key} and is no '
              'longer created at all',
        );
        expect(
          current!,
          containsAll(table.value),
          reason: '${table.key}: these columns shipped at v${version.key} and '
              'are gone from the DDL: '
              '${table.value.difference(current).join(", ")}. A rolled-back '
              'build would still query them.',
        );
      }
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
