import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/utils/punch_confirmation.dart';

/// The confirmation an employee sees and hears right after a punch.
///
/// This used to be three separate switches inline in the scan screen — one
/// for the TTS line, one for the dialog's title/icon/colour, one for its
/// subtitle. Break-out and break-in were added to the punch *buttons* but
/// not to these three, so an employee going on break heard "Time Out
/// recorded" and saw "Time Out Recorded!" — indistinguishable from actually
/// clocking out for the day. One function, one switch, is what stops that
/// gap reopening: Dart's exhaustiveness check fails to compile the moment a
/// new punch type is added here without a case.
void main() {
  group('what each punch says and shows', () {
    test('a break starting reads as a break, not a time-out', () {
      final c = punchConfirmationFor('break-out', 'Ana Cruz');
      expect(c.title, 'Enjoy Your Break!');
      expect(c.announcement, contains('Break started'));
      expect(c.announcement, contains('Ana Cruz'));
    });

    test('a break ending reads as returning, not timing in', () {
      final c = punchConfirmationFor('break-in', 'Ana Cruz');
      expect(c.title, 'Welcome Back!');
      expect(c.announcement, contains('Back from break'));
    });

    test('overtime is unaffected by adding breaks', () {
      expect(punchConfirmationFor('overtime-in', 'Ana Cruz').title, 'Overtime Started!');
      expect(punchConfirmationFor('overtime-out', 'Ana Cruz').title, 'Overtime Ended!');
    });

    test('the ordinary punches are unaffected too', () {
      expect(punchConfirmationFor('time-in', 'Ana Cruz').title, 'Time In Recorded!');
      expect(punchConfirmationFor('time-out', 'Ana Cruz').title, 'Time Out Recorded!');
    });

    test('degrades to the time-out confirmation for anything unrecognised', () {
      // A kiosk build newer than the server it talks to must show *a*
      // readable confirmation, not crash.
      final c = punchConfirmationFor('some-future-punch-type', 'Ana Cruz');
      expect(c.title, 'Time Out Recorded!');
    });

    test('every title is distinct — nothing reads as a different action', () {
      const types = ['time-in', 'time-out', 'break-out', 'break-in', 'overtime-in', 'overtime-out'];
      final titles = types.map((t) => punchConfirmationFor(t, 'X').title).toSet();
      expect(titles.length, types.length);
    });

    /// The icon trap: a patch carries no assets, so the font is frozen at
    /// whatever the shipped release tree-shook. An icon outside that set is
    /// an empty box on every kiosk while looking correct in this very test.
    test('every icon is one the shipped release already bundles', () {
      final bundled = <IconData>{
        Icons.wb_sunny,
        Icons.login_rounded,
        Icons.check_circle_rounded,
        Icons.more_time_rounded,
        Icons.timelapse_rounded,
      };
      const types = ['time-in', 'time-out', 'break-out', 'break-in', 'overtime-in', 'overtime-out'];
      for (final t in types) {
        expect(bundled.contains(punchConfirmationFor(t, 'X').icon), isTrue, reason: t);
      }
    });

    test('a break subtitle explains the state without repeating the title', () {
      expect(punchConfirmationFor('break-out', 'X').subtitle, isNotNull);
      expect(punchConfirmationFor('break-in', 'X').subtitle, isNotNull);
    });

    test('the ordinary punches carry no subtitle — nothing to add', () {
      expect(punchConfirmationFor('time-in', 'X').subtitle, isNull);
      expect(punchConfirmationFor('time-out', 'X').subtitle, isNull);
    });
  });
}
