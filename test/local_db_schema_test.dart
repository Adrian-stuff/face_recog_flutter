import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/services/local_database_service.dart';

/// The reconciliation rule behind [LocalDatabaseService] keeping a device's
/// schema correct on every open.
///
/// A kiosk was bricked because the migrations trusted `user_version` to
/// describe the real schema. It didn't: the device already had
/// `client_event_id` while its version said 5, so the v6 migration re-added
/// the column, threw, and — since sqflite wraps onUpgrade in a transaction —
/// rolled back without advancing the version. Same failure every launch,
/// forever, and the database never opened again.
///
/// These cover the decision itself. The SQL it drives was verified separately
/// against real SQLite databases built in each historical device state,
/// including that one.
void main() {
  group('missingColumns', () {
    const target = {
      'client_event_id': 'TEXT',
      'app_version': 'TEXT',
      'lat': 'REAL',
    };

    test('reports nothing when the table already has everything', () {
      expect(
        LocalDatabaseService.missingColumns(
          {'id', 'client_event_id', 'app_version', 'lat'},
          target,
        ),
        isEmpty,
      );
    });

    // The field bug in miniature: the column is present even though the
    // version number implies it shouldn't be. Re-adding it is what threw.
    test('skips a column that exists despite what the version claims', () {
      final missing = LocalDatabaseService.missingColumns(
        {'id', 'client_event_id'},
        target,
      );
      expect(missing.map((e) => e.key), isNot(contains('client_event_id')));
      expect(missing.map((e) => e.key), containsAll(['app_version', 'lat']));
    });

    test('reports every column on a table that predates all of them', () {
      final missing = LocalDatabaseService.missingColumns({'id'}, target);
      expect(missing.map((e) => e.key), containsAll(target.keys));
      expect(missing.length, target.length);
    });

    test('carries the column type through, so the ALTER is well-formed', () {
      final missing = LocalDatabaseService.missingColumns({'id'}, target);
      expect(
        Map.fromEntries(missing),
        equals(target),
        reason: 'a dropped or altered type would produce invalid SQL',
      );
    });

    // Reconciliation runs on every open, so a second pass over an
    // already-corrected table has to be a no-op — otherwise the fix would
    // reintroduce the duplicate-column crash it exists to prevent.
    test('is idempotent: nothing left to add once applied', () {
      final actual = {'id', ...target.keys};
      expect(LocalDatabaseService.missingColumns(actual, target), isEmpty);
    });

    test('ignores extra columns the target does not know about', () {
      expect(
        LocalDatabaseService.missingColumns(
          {'id', 'legacy_column', ...target.keys},
          target,
        ),
        isEmpty,
      );
    });
  });
}
