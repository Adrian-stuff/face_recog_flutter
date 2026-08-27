import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/supabase_service.dart';
import 'package:mobile_app/widgets/scan_target_bar.dart';

/// Break punches on the kiosk.
///
/// Breaks cannot borrow the trick overtime uses — the kiosk sends `time-in`
/// and lets the server reinterpret it — because a `time-in` arriving after a
/// break is indistinguishable from an overtime-in. So they are explicit on
/// the wire, and what these pin down is that the state line, the icons and
/// the vocabulary all agree about that.

const _ana = <String, dynamic>{
  'id': 1,
  'first_name': 'Ana',
  'last_name': 'Cruz',
  'position': 'Machinist',
};

Future<void> _pump(WidgetTester tester, String? nextAction) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ScanTargetBar(
          employee: _ana,
          nextAction: nextAction,
          isLoadingNextAction: false,
          onChange: () {},
          onSelect: () {},
        ),
      ),
    ),
  );
}

void main() {
  /// Whether an offline kiosk may narrow its buttons to one action.
  ///
  /// A single-kiosk company's device history *is* the whole story, so making
  /// it wait for the server is over-cautious. But "one kiosk" is not "one
  /// punch source" — the browser time-in page writes through the same
  /// recorder, and dashboard corrections never reach the device — so the
  /// permission is granted by the server, not assumed here.
  ///
  /// Narrowing on a wrong answer strands an employee with no way to clock
  /// out, so every case that is not an explicit yes must be a no.
  group('mayTrustLocalHistory', () {
    Map<String, dynamic> cache({
      String date = '2026-08-27',
      bool soleWriter = true,
      Map<String, dynamic>? employees,
    }) => {
      'date': date,
      'soleWriter': soleWriter,
      'employees': employees ?? {'42': true},
    };

    test('yes when the server said sole writer and answered for this employee today', () {
      expect(
        SupabaseService.mayTrustLocalHistory(cache(), '2026-08-27', 42),
        isTrue,
      );
    });

    test('no when another kiosk or the web page also writes', () {
      expect(
        SupabaseService.mayTrustLocalHistory(
          cache(soleWriter: false),
          '2026-08-27',
          42,
        ),
        isFalse,
      );
    });

    /// The reinstall case. A wiped database reads as "never timed in" for
    /// everybody, and an empty cache is what stops the kiosk acting on it.
    test('no when the server has not answered for this employee today', () {
      expect(
        SupabaseService.mayTrustLocalHistory(cache(), '2026-08-27', 99),
        isFalse,
      );
      expect(SupabaseService.mayTrustLocalHistory(null, '2026-08-27', 42), isFalse);
      expect(
        SupabaseService.mayTrustLocalHistory({'date': '2026-08-27'}, '2026-08-27', 42),
        isFalse,
      );
    });

    /// Yesterday's permission says nothing about today — the employee may
    /// have punched on the web page overnight.
    test('no once the day has rolled over', () {
      expect(
        SupabaseService.mayTrustLocalHistory(cache(date: '2026-08-26'), '2026-08-27', 42),
        isFalse,
      );
    });

    test('no for anything it cannot read, rather than throwing', () {
      for (final junk in <Object?>[null, 'nonsense', 7, <int>[1, 2]]) {
        expect(
          SupabaseService.mayTrustLocalHistory(junk, '2026-08-27', 42),
          isFalse,
        );
      }
    });

    test('no when the flag is present but not literally true', () {
      // A server sending "true" as a string, or 1, is not an authorisation.
      for (final loose in <Object?>['true', 1, 'yes']) {
        expect(
          SupabaseService.mayTrustLocalHistory(
            {'date': '2026-08-27', 'soleWriter': loose, 'employees': {'42': true}},
            '2026-08-27',
            42,
          ),
          isFalse,
        );
      }
    });
  });

  group('shiftStateDisplay', () {
    test('says an employee is on a break rather than merely on the clock', () {
      expect(shiftStateDisplay('break-in').label, 'On a break');
    });

    test('says a break is available without implying one is running', () {
      expect(shiftStateDisplay('break-out').label, contains('can take a break'));
    });

    /// A patch carries Dart code and no assets, so the icon font on the device
    /// stays frozen at whatever the release tree-shook. An icon outside that
    /// set renders as an empty box on every kiosk while looking perfect in a
    /// local build and in every test — which is why this is asserted rather
    /// than left to the eye.
    test('draws breaks with glyphs the shipped release already bundles', () {
      final bundled = <IconData>{
        Icons.wb_sunny,
        Icons.login_rounded,
        Icons.logout,
        Icons.login,
        Icons.access_time_rounded,
        Icons.more_time_rounded,
        Icons.timelapse_rounded,
        Icons.check_circle_outline_rounded,
        Icons.verified_rounded,
      };
      for (final action in ['break-out', 'break-in']) {
        expect(
          bundled.contains(shiftStateDisplay(action).icon),
          isTrue,
          reason: '$action uses an icon outside the release font',
        );
      }
    });

    test('keeps every state distinguishable from every other', () {
      const states = [
        'time-in',
        'time-out',
        'break-out',
        'break-in',
        'overtime-in',
        'overtime-out',
        'done',
      ];
      final labels = states.map((s) => shiftStateDisplay(s).label).toSet();
      expect(labels.length, states.length);
    });

    /// The kiosks patch gradually, so a device carrying break code will meet
    /// a server that has never heard of them and vice versa. Neither may
    /// produce a blank or misleading line.
    test('falls back to a safe line for an action it does not know', () {
      expect(shiftStateDisplay('siesta').label, 'Ready to verify');
      expect(shiftStateDisplay(null).label, 'Ready to verify');
    });
  });

  group('the bar itself', () {
    testWidgets('spells out that the employee is on a break', (tester) async {
      await _pump(tester, 'break-in');
      expect(find.text('On a break'), findsOneWidget);
      expect(find.text('Ana Cruz'), findsOneWidget);
    });

    testWidgets('does not claim a break is running when one merely could be', (
      tester,
    ) async {
      await _pump(tester, 'time-out');
      expect(find.text('On a break'), findsNothing);
    });

    testWidgets('renders a break state without overflowing', (tester) async {
      // The bar is one line beside a 52px avatar and a Change button; the
      // longer phrasings have ellipsised their own last word before.
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester, 'break-out');
      expect(tester.takeException(), isNull);
    });
  });
}
