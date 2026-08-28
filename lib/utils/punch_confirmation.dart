import 'package:flutter/material.dart';
import '../config/kiosk_config.generated.dart';

/// What to say, show, and colour for a punch that just succeeded.
///
/// Pulled out of the scan screen's success handler because that handler had
/// three separate switches on the same punch type — the TTS announcement,
/// the dialog's title/icon/colour, and its subtitle — and they drifted:
/// break-out and break-in were added to the *buttons* but not to this
/// confirmation flow, so an employee going on break heard "Time Out
/// recorded" and saw "Time Out Recorded!", indistinguishable from actually
/// clocking out for the day. One function that has to name every punch type
/// exhaustively is what stops that gap reopening — Dart's exhaustiveness
/// check on the switch fails to compile if a new PunchType value shows up
/// here without a case.
class PunchConfirmation {
  final String announcement;
  final String title;
  final IconData icon;
  final Color color;
  final String? subtitle;

  const PunchConfirmation({
    required this.announcement,
    required this.title,
    required this.icon,
    required this.color,
    this.subtitle,
  });
}

/// [effectiveType] is the type actually recorded — after any
/// reinterpretation (a device-sent `time-in` that became an overtime-in) —
/// which is what the employee needs to hear confirmed, not what they tapped.
PunchConfirmation punchConfirmationFor(String effectiveType, String name) =>
    switch (effectiveType) {
      'overtime-in' => PunchConfirmation(
        announcement: 'Overtime In recorded for $name',
        title: 'Overtime Started!',
        icon: Icons.more_time_rounded,
        color: const Color(0xFF00897B), // teal
        subtitle: 'Overtime session has started.',
      ),
      'overtime-out' => PunchConfirmation(
        announcement: 'Overtime Out recorded for $name',
        title: 'Overtime Ended!',
        icon: Icons.timelapse_rounded,
        color: const Color(0xFFE65100), // deep-orange
        subtitle: 'Overtime session has ended.',
      ),
      'break-out' => PunchConfirmation(
        announcement: 'Break started for $name',
        title: 'Enjoy Your Break!',
        // Same glyph the START BREAK button uses. There is no coffee cup in
        // the 84 icons release 1.2.0+67 bundles, and a patch carries no
        // assets, so anything outside that set is an empty box on every
        // kiosk while looking correct locally.
        icon: Icons.wb_sunny,
        color: const Color(0xFF6A4CB8),
        subtitle: 'Break has started. Tap in when you are back.',
      ),
      'break-in' => PunchConfirmation(
        announcement: 'Back from break for $name',
        title: 'Welcome Back!',
        icon: Icons.login_rounded,
        color: KioskColors.success,
        subtitle: 'Break has ended — back on the clock.',
      ),
      'time-in' => PunchConfirmation(
        announcement: 'Time In recorded for $name',
        title: 'Time In Recorded!',
        icon: Icons.check_circle_rounded,
        color: KioskColors.success,
      ),
      // 'time-out' and anything unrecognised. Unrecognised falls here rather
      // than to a dedicated error case because a kiosk build newer than the
      // server it talks to must degrade to *a* readable confirmation, not a
      // crash — see the vocabulary note on isPunchAllowed's server-side twin.
      _ => PunchConfirmation(
        announcement: 'Time Out recorded for $name',
        title: 'Time Out Recorded!',
        icon: Icons.check_circle_rounded,
        color: KioskColors.success,
      ),
    };
