import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/utils/punch_rules.dart';

/// The kiosk's own copy of "what can this employee punch next", and the
/// guard that decides whether a break punch even leaves the device.
///
/// Both lived inline in SupabaseService — a hard singleton that wires up
/// Supabase, the local database and the network service in its constructor,
/// so neither could be reached from a test without a real device. They
/// decide which buttons appear and whether a punch is refused at the wall,
/// which makes them the two worst things in this app to have left unverified.
///
/// The state table below deliberately mirrors the server's
/// `__tests__/utils/punch-state.test.ts` case for case. The two rules are
/// separate implementations in separate languages and nothing mechanically
/// enforces that they agree; matching test tables at least make a divergence
/// visible to a reviewer looking at either side.
void main() {
  const notIn = LocalPunchHistory();
  const onClock = LocalPunchHistory(hasTimedIn: true);
  const onBreak = LocalPunchHistory(hasTimedIn: true, onBreak: true);
  const shiftDone = LocalPunchHistory(hasTimedIn: true, hasTimedOut: true);
  const onOvertime = LocalPunchHistory(
    hasTimedIn: true,
    hasTimedOut: true,
    hasOvertimeIn: true,
  );
  const allDone = LocalPunchHistory(
    hasTimedIn: true,
    hasTimedOut: true,
    hasOvertimeIn: true,
    hasOvertimeOut: true,
  );

  List<String> allowed(LocalPunchHistory h) {
    final s = localNextPunch(h);
    return s.action == 'done' ? const [] : [s.action, ...s.alsoAllowed];
  }

  group('every state, and what it permits', () {
    test('before the shift: time in, and nothing else', () {
      expect(allowed(notIn), ['time-in']);
    });

    /// The only state with two valid punches — go home, or go on break.
    test('on the clock: go home or go on break', () {
      expect(localNextPunch(onClock).action, 'time-out');
      expect(localNextPunch(onClock).alsoAllowed, ['break-out']);
    });

    test('on a break: only coming back', () {
      expect(allowed(onBreak), ['break-in']);
    });

    test('shift finished: overtime is offered', () {
      expect(allowed(shiftDone), ['overtime-in']);
    });

    test('on overtime: only closing it', () {
      expect(allowed(onOvertime), ['overtime-out']);
    });

    /// The server never returns "done" (it does not load closed overtime
    /// sessions); the device can, because it knows its own history.
    test('everything finished: nothing at all', () {
      expect(localNextPunch(allDone).action, 'done');
      expect(allowed(allDone), isEmpty);
    });
  });

  group('the precedence order, and what each rung protects', () {
    /// Ending a shift with the break still running leaves a session nobody
    /// closed, which payroll then falls back to the rostered figure for.
    test('an open break outranks the time-out', () {
      expect(localNextPunch(onBreak).action, 'break-in');
      expect(allowed(onBreak), isNot(contains('time-out')));
    });

    test('a break is not offered before timing in', () {
      expect(allowed(notIn), isNot(contains('break-out')));
    });

    test('a break is not offered after timing out', () {
      expect(allowed(shiftDone), isNot(contains('break-out')));
    });

    test('never more than one way to end the shift', () {
      for (final h in [notIn, onClock, onBreak, shiftDone, onOvertime, allDone]) {
        final ends = allowed(h).where((p) => p == 'time-out' || p == 'overtime-out');
        expect(ends.length, lessThanOrEqualTo(1));
      }
    });

    test('the leading action is always itself permitted', () {
      for (final h in [notIn, onClock, onBreak, shiftDone, onOvertime]) {
        expect(allowed(h), contains(localNextPunch(h).action));
      }
    });
  });

  /// The guard that runs before a break punch is queued at all.
  ///
  /// `askServer` is not caution for its own sake: local history excludes rows
  /// carrying a sync error, so one rejected break-out upload erases the
  /// session from this device while the server keeps it open. Refusing on
  /// that basis locks the employee out of ending their own break — the
  /// overtime bug this app already paid for once.
  group('the break guard', () {
    test('sends a break-out from someone on the clock', () {
      expect(breakGuardFor('break-out', onClock), BreakGuardVerdict.send);
    });

    test('sends a break-in from someone on a break', () {
      expect(breakGuardFor('break-in', onBreak), BreakGuardVerdict.send);
    });

    test('asks the server before refusing a break-in', () {
      // Local says "not on a break" — but local may simply not know.
      expect(breakGuardFor('break-in', onClock), BreakGuardVerdict.askServer);
      expect(breakGuardFor('break-in', notIn), BreakGuardVerdict.askServer);
    });

    test('asks the server before refusing a second break-out', () {
      expect(breakGuardFor('break-out', onBreak), BreakGuardVerdict.askServer);
    });

    /// Unlike the two above, this is not a gap in local knowledge the server
    /// might fill: a break belongs to a shift, and the device knows whether
    /// it recorded one.
    test('refuses a break with no shift outright, without asking', () {
      expect(breakGuardFor('break-out', notIn), BreakGuardVerdict.refuse);
      expect(breakGuardFor('break-out', shiftDone), BreakGuardVerdict.refuse);
    });

    test('has no opinion on the other punch types', () {
      for (final t in ['time-in', 'time-out', 'overtime-in', 'overtime-out']) {
        expect(breakGuardFor(t, notIn), BreakGuardVerdict.send, reason: t);
      }
    });
  });

  group('the refusal messages', () {
    test('name the actual problem, not a generic failure', () {
      expect(breakRefusalMessage('break-in', onClock), contains('not currently on a break'));
      expect(breakRefusalMessage('break-out', onBreak), contains('already on a break'));
      expect(breakRefusalMessage('break-out', notIn), contains('timed in'));
    });

    test('every refusable state has a sentence, none empty', () {
      final cases = <(String, LocalPunchHistory)>[
        ('break-in', onClock),
        ('break-in', notIn),
        ('break-out', onBreak),
        ('break-out', notIn),
        ('break-out', shiftDone),
      ];
      for (final (type, history) in cases) {
        expect(breakRefusalMessage(type, history), isNotEmpty, reason: '$type / $history');
      }
    });
  });

  /// The gap the whole soleWriter mechanism exists to cover: this rule is
  /// only ever an estimate. These pin the cases where it is knowably wrong,
  /// so nobody later mistakes it for authoritative.
  group('what this rule cannot know', () {
    test('a wiped database reads as "never timed in" for everybody', () {
      // Which is correct behaviour *for the rule* — it is the caller's job
      // not to treat it as authoritative. See mayTrustLocalHistory.
      expect(localNextPunch(notIn).action, 'time-in');
    });

    test('an overtime session from yesterday is invisible here', () {
      // Local history is today-scoped, so yesterday's open session reads as
      // a clean slate. Only the server sees it.
      expect(localNextPunch(notIn).action, isNot('overtime-out'));
    });
  });
}
