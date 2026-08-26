import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/services/local_database_service.dart';

/// Face descriptors have to survive the round trip into SQLite.
///
/// They did not. supabase_service.syncEmployees() jsonEncode()s the descriptor
/// list into a String, and the local syncEmployees() encoded that String a
/// second time — so the column held JSON *inside* a JSON string.
/// parseFaceFeatures decodes once, got a String back where it expected a List,
/// matched none of its branches, and cached nothing. Every employee ended up
/// with no local face data.
///
/// Online this was invisible: verifyFaceAgainstEmployee falls through to a
/// server-side match whenever the local comparison does not confirm. Offline
/// there is no fallback, so turning the WiFi off left the kiosk unable to
/// match anyone — which is exactly how it was reported.
void main() {
  final descriptors = [
    {'descriptor': List<double>.filled(192, 0.1), 'is_golden': true},
    {'descriptor': List<double>.filled(192, 0.2), 'is_golden': false},
  ];

  group('parseFaceFeatures', () {
    test('reads the JSON string supabase_service actually writes', () {
      final entries = LocalDatabaseService.parseFaceFeatures(
        jsonEncode(descriptors),
      );

      expect(entries, hasLength(2));
      expect(entries.first['isGolden'], isTrue);
      expect(entries.first['descriptor'], hasLength(192));
    });

    /// The regression. Devices synced before the fix hold this shape, and they
    /// are the ones stuck offline — they must not have to reach the server
    /// again to become usable.
    test('recovers a value that was written double-encoded', () {
      final entries = LocalDatabaseService.parseFaceFeatures(
        jsonEncode(jsonEncode(descriptors)),
      );

      expect(
        entries,
        hasLength(2),
        reason: 'the extra JSON layer should be unwrapped, not discarded',
      );
    });

    test('still reads the legacy bare-vector format', () {
      final legacy = [List<double>.filled(192, 0.3)];

      final entries = LocalDatabaseService.parseFaceFeatures(jsonEncode(legacy));

      expect(entries, hasLength(1));
      expect(entries.first['isGolden'], isFalse);
    });

    test('reads a legacy single vector', () {
      final entries = LocalDatabaseService.parseFaceFeatures(
        jsonEncode(List<double>.filled(192, 0.4)),
      );

      expect(entries, hasLength(1));
      expect(entries.first['descriptor'], hasLength(192));
    });

    test('returns nothing for an employee with no enrolled face', () {
      expect(LocalDatabaseService.parseFaceFeatures(null), isEmpty);
      expect(LocalDatabaseService.parseFaceFeatures(''), isEmpty);
    });

    /// Never throw. This runs while building the cache for the whole roster,
    /// and one corrupt row must not take every other employee's face with it.
    test('survives a corrupt value without throwing', () {
      expect(LocalDatabaseService.parseFaceFeatures('not json at all'), isEmpty);
      expect(LocalDatabaseService.parseFaceFeatures('{"unexpected":"shape"}'), isEmpty);
      expect(LocalDatabaseService.parseFaceFeatures('[]'), isEmpty);
    });

    test('skips entries whose descriptor cannot be coerced', () {
      final mixed = [
        {'descriptor': List<double>.filled(192, 0.1), 'is_golden': true},
        {'descriptor': null, 'is_golden': false},
      ];

      expect(LocalDatabaseService.parseFaceFeatures(jsonEncode(mixed)), hasLength(1));
    });
  });
}
