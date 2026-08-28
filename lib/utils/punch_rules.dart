/// The kiosk's own answers to "what can this employee punch next?" and
/// "should this punch be refused before it leaves the device?".
///
/// Both used to live inline in SupabaseService, which is a hard singleton
/// wiring up Supabase, the local database and the network service in its
/// constructor — so neither could be tested without a device. They decide
/// which buttons an employee sees and whether their punch is refused at the
/// wall, which makes them the two worst things in this app to leave
/// unverified.
///
/// Pure and synchronous: every caller has already done the database work.
/// Same shape, and the same precedence order, as the server's
/// `src/punch-state.ts`. The two are separate implementations in separate
/// languages and nothing mechanically enforces that they agree — [localNextPunch]'s
/// test table is written to mirror `__tests__/utils/punch-state.test.ts`
/// case for case so a divergence is at least visible in review.
library;

/// What this device believes the employee has punched today.
///
/// Every field is "as far as this device knows" — a punch made on another
/// kiosk, or before a reinstall, simply is not here. That is exactly why the
/// result is only ever treated as authoritative when the server has said this
/// device is the sole writer.
class LocalPunchHistory {
  /// More break-outs than break-ins: the employee is on a break right now.
  final bool onBreak;
  final bool hasTimedIn;
  final bool hasTimedOut;
  final bool hasOvertimeIn;
  final bool hasOvertimeOut;

  const LocalPunchHistory({
    this.onBreak = false,
    this.hasTimedIn = false,
    this.hasTimedOut = false,
    this.hasOvertimeIn = false,
    this.hasOvertimeOut = false,
  });
}

/// The leading action, plus any others equally valid right now.
typedef LocalPunchState = ({String action, List<String> alsoAllowed});

/// Precedence, and why it is this order — matching the server exactly:
///
///  1. An open break outranks everything, including a time-out. Ending a
///     shift with the break still running leaves a session nobody closed,
///     which payroll then falls back to the rostered figure for.
///  2. Then the ordinary shift: in, then out. Mid-shift a break is *also*
///     valid, which is the one state with two answers.
///  3. A finished shift offers overtime, then closing it, then nothing.
LocalPunchState localNextPunch(LocalPunchHistory history) {
  const none = <String>[];

  if (history.onBreak) return (action: 'break-in', alsoAllowed: none);
  if (!history.hasTimedIn) return (action: 'time-in', alsoAllowed: none);
  if (!history.hasTimedOut) {
    return (action: 'time-out', alsoAllowed: const <String>['break-out']);
  }
  if (!history.hasOvertimeIn) return (action: 'overtime-in', alsoAllowed: none);
  if (!history.hasOvertimeOut) {
    return (action: 'overtime-out', alsoAllowed: none);
  }
  return (action: 'done', alsoAllowed: none);
}

/// What the device should do with a break punch before sending it.
enum BreakGuardVerdict {
  /// Nothing local contradicts it — send it.
  send,

  /// Local history says no, but local history is not trustworthy enough to
  /// refuse on alone. Ask the server, and only refuse if it agrees.
  askServer,

  /// Refuse outright: the employee is demonstrably not in a state where this
  /// punch means anything, and no server answer would change that.
  refuse,
}

/// Whether a break punch should be sent, checked with the server, or refused.
///
/// The `askServer` verdicts are not caution for its own sake. Local history
/// excludes rows carrying a sync error, so a single rejected break-out upload
/// erases the session from this device's memory while the server keeps it
/// open — refusing on that basis locks the employee out of ending their own
/// break. That is the overtime bug this app already paid for once; the
/// comment describing it still sits in SupabaseService's overtime branch.
///
/// [type] must be `break-out` or `break-in`; anything else returns [send],
/// since this guard has no opinion on the other punch types.
BreakGuardVerdict breakGuardFor(String type, LocalPunchHistory history) {
  if (type == 'break-in') {
    // Local says they are not on a break. It may simply not know.
    return history.onBreak ? BreakGuardVerdict.send : BreakGuardVerdict.askServer;
  }

  if (type == 'break-out') {
    // Already on a break by local reckoning — again, worth confirming.
    if (history.onBreak) return BreakGuardVerdict.askServer;

    // Not on the clock at all. Unlike the two above, this is not a gap in
    // local knowledge that the server might fill: a break belongs to a shift,
    // and this device knows whether it recorded one. Refusing here keeps a
    // meaningless punch off the queue entirely.
    if (!history.hasTimedIn || history.hasTimedOut) {
      return BreakGuardVerdict.refuse;
    }

    return BreakGuardVerdict.send;
  }

  return BreakGuardVerdict.send;
}

/// The message shown when [breakGuardFor] refuses, or when the server agrees
/// with a local `askServer` refusal.
///
/// Kept beside the rule so a new verdict cannot be added without a sentence
/// for the person standing at the kiosk.
String breakRefusalMessage(String type, LocalPunchHistory history) {
  if (type == 'break-in') return 'You are not currently on a break.';
  if (history.onBreak) return 'You are already on a break. Punch back in first.';
  return 'You have to be timed in to take a break.';
}
