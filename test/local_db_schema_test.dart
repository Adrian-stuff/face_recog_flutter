import 'dart:io';

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
  group('every table is inside the reconciliation net', () {
    /// The tables the service actually creates, read off its own DDL rather
    /// than restated here — a list maintained by hand is a list that drifts.
    ///
    /// This is the check that was missing. `_reconcileSchema` skips any table
    /// absent from the declared target, so a table created by onCreate but
    /// never declared gets no self-healing at all: a column added to it
    /// arrives only if onUpgrade fires, which is the assumption reconciliation
    /// exists precisely because it cannot rely on. scan_events and
    /// error_reports sat outside it for their whole lifetime.
    test('declares every table it creates', () {
      final source = File(
        'lib/services/local_database_service.dart',
      ).readAsStringSync();

      final created = RegExp(r'CREATE TABLE (?:IF NOT EXISTS )?([a-z_]+)')
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();

      final declared = LocalDatabaseService.expectedColumnsForTesting.keys.toSet();

      expect(
        created.difference(declared),
        isEmpty,
        reason:
            'These tables are created but not declared in _expectedColumns, so '
            '_reconcileSchema will never repair them: '
            '${created.difference(declared).join(", ")}',
      );
    });

    /// A table has to be created on both routes into the schema.
    ///
    /// `_reconcileSchema` deliberately skips a table that does not exist —
    /// creating one is onCreate's job, and inventing it would mask a real
    /// problem. So a table wired only into onUpgrade never reaches a fresh
    /// install, and one wired only into onCreate never reaches an existing
    /// device. Neither failure is visible until something tries to write to
    /// it, and the self-healing that covers a missing *column* does not cover
    /// a missing *table*.
    ///
    /// Sharing one DDL constant between the two paths is what makes them
    /// agree; this asserts both paths actually use it.
    test('creates every table on both the fresh-install and upgrade paths', () {
      final source = File(
        'lib/services/local_database_service.dart',
      ).readAsStringSync();

      final onCreateAt = source.indexOf('onCreate:');
      final onUpgradeAt = source.indexOf('onUpgrade:');
      expect(onCreateAt, greaterThan(-1));
      expect(onUpgradeAt, greaterThan(onCreateAt));

      final ddlConstants = RegExp(r'static const String (_create\w+Sql)')
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      expect(ddlConstants, isNotEmpty, reason: 'no CREATE TABLE constants found');

      for (final name in ddlConstants) {
        final uses = RegExp('\\b$name\\b')
            .allMatches(source)
            .map((m) => m.start)
            // The declaration itself sits after both handlers; ignore it.
            .where((at) => at < source.indexOf('static const String $name'))
            .toList();

        expect(
          uses.where((at) => at > onCreateAt && at < onUpgradeAt),
          isNotEmpty,
          reason: '$name is never executed from onCreate — fresh installs '
              'will not have this table',
        );
        expect(
          uses.where((at) => at > onUpgradeAt),
          isNotEmpty,
          reason: '$name is never executed from onUpgrade — existing devices '
              'will not have this table',
        );
      }
    });

    /// ALTER TABLE ADD COLUMN cannot add a NOT NULL column without a default,
    /// so declaring one would make reconciliation throw on the devices that
    /// need it most — the ones whose upgrade already failed.
    test('declares nothing that cannot be added by ALTER TABLE', () {
      for (final table in LocalDatabaseService.expectedColumnsForTesting.entries) {
        for (final column in table.value.entries) {
          final type = column.value.toUpperCase();
          if (type.contains('NOT NULL')) {
            expect(
              type,
              contains('DEFAULT'),
              reason:
                  '${table.key}.${column.key} is NOT NULL with no DEFAULT — '
                  'ALTER TABLE ADD COLUMN cannot add that to an existing table.',
            );
          }
          expect(
            type,
            isNot(contains('PRIMARY KEY')),
            reason:
                '${table.key}.${column.key} declares a PRIMARY KEY, which can '
                'only be set when the table is created.',
          );
        }
      }
    });
  });
}
