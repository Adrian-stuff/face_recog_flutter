import 'package:flutter/material.dart';

import '../config/kiosk_config.generated.dart';
import '../utils/employee_display.dart';

/// Where an employee stands today, derived from this device's punch history.
enum RollCallStatus {
  /// No time-in recorded today.
  notIn,

  /// Timed in, no time-out yet.
  onTheClock,

  /// Regular shift closed, overtime session still open.
  overtime,

  /// Both punches recorded and no overtime pending.
  done,
}

/// [RollCallStatus] plus the timestamp of the punch that opened the current
/// stretch — null unless the employee is actually on the clock.
typedef RollCallState = ({RollCallStatus status, String? since});

/// Reads an employee's day out of the punch map returned by
/// `LocalDatabaseService.getTodayPunchesByEmployee`.
///
/// An open overtime session counts as being on the clock, so someone working
/// overtime lands in the "still in" column rather than reading as finished
/// for the day just because their regular time-out exists.
RollCallState rollCallStateFor(Map<String, String> punches) {
  final timeIn = punches['time-in'];
  final timeOut = punches['time-out'];
  final overtimeIn = punches['overtime-in'];
  final overtimeOut = punches['overtime-out'];

  if (timeIn == null) return (status: RollCallStatus.notIn, since: null);
  if (timeOut == null) {
    return (status: RollCallStatus.onTheClock, since: timeIn);
  }
  if (overtimeIn != null && overtimeOut == null) {
    return (status: RollCallStatus.overtime, since: overtimeIn);
  }
  return (status: RollCallStatus.done, since: null);
}

/// Two columns of names: who hasn't timed in yet, and who is on the clock and
/// still owes a time-out.
///
/// Replaces the month calendar that used to sit on the scan screen. A kiosk
/// only ever deals with today, so a calendar answered a question nobody
/// standing at it was asking, while the one they do ask out loud — "has
/// so-and-so come in yet?" — needed an admin or a separate screen.
///
/// Employees who have finished for the day appear in neither column; the
/// footer keeps them counted so the numbers still add up to the roster.
class RollCallPanel extends StatelessWidget {
  const RollCallPanel({
    super.key,
    required this.employees,
    required this.punches,
    this.selectedEmployeeId,
    this.onSelect,
  });

  /// The same roster the selector behind this panel offers, so a name can't
  /// appear in the roll call but be missing from the search sheet.
  final List<Map<String, dynamic>> employees;

  /// Employee id -> attendance type -> timestamp, for today only.
  final Map<int, Map<String, String>> punches;

  final int? selectedEmployeeId;

  /// Null disables tapping — used while a scan is already in flight.
  final void Function(Map<String, dynamic> employee)? onSelect;

  RollCallState _stateFor(int id) =>
      rollCallStateFor(punches[id] ?? const <String, String>{});

  @override
  Widget build(BuildContext context) {
    final notIn = <Map<String, dynamic>>[];
    final stillIn = <Map<String, dynamic>>[];
    var done = 0;

    for (final employee in employees) {
      final id = employee['id'];
      if (id is! int) continue;
      switch (_stateFor(id).status) {
        case RollCallStatus.notIn:
          notIn.add(employee);
        case RollCallStatus.onTheClock:
        case RollCallStatus.overtime:
          stillIn.add(employee);
        case RollCallStatus.done:
          done++;
      }
    }

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Takes the height the screen has left rather than a fixed
            // amount, so the roll call grows into a tall kiosk instead of
            // leaving a band of dead space above the punch buttons. Each
            // column scrolls on its own inside whatever it gets, which keeps
            // every name reachable without truncating the list to a
            // "+12 more" — and keeps a long roster from pushing the buttons
            // off the bottom. Requires a bounded parent (Expanded, or a
            // Scaffold body); this must not go inside a scroll view.
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _RollCallColumn(
                      title: 'Not timed in',
                      // Both column icons are deliberately picked from the
                      // glyphs the shipped release already bundles. Flutter
                      // tree-shakes MaterialIcons to what a build references,
                      // and a Shorebird patch carries code only — never
                      // assets — so a "nicer" icon that wasn't in the release
                      // renders as an empty box on every patched kiosk.
                      // hourglass_empty_rounded and timer_outlined were the
                      // first choices here and are exactly that trap.
                      icon: Icons.login,
                      color: KioskColors.warning,
                      employees: notIn,
                      emptyMessage: employees.isEmpty
                          ? 'No employees yet.'
                          : 'Everyone has timed in.',
                      stateFor: _stateFor,
                      selectedEmployeeId: selectedEmployeeId,
                      onSelect: onSelect,
                    ),
                  ),
                  const VerticalDivider(width: 17, thickness: 1),
                  Expanded(
                    child: _RollCallColumn(
                      title: 'Still timed in',
                      icon: Icons.access_time_rounded,
                      color: KioskColors.success,
                      employees: stillIn,
                      emptyMessage: 'Nobody is on the clock.',
                      stateFor: _stateFor,
                      selectedEmployeeId: selectedEmployeeId,
                      onSelect: onSelect,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            // The device can only report punches it took itself — see
            // getTodayPunchesByEmployee. Saying so is cheaper than letting
            // someone read a missing name as a missing punch.
            Text(
              done > 0
                  ? '$done finished for the day · punches recorded on this device'
                  : 'Punches recorded on this device',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: KioskColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _RollCallColumn extends StatelessWidget {
  const _RollCallColumn({
    required this.title,
    required this.icon,
    required this.color,
    required this.employees,
    required this.emptyMessage,
    required this.stateFor,
    required this.selectedEmployeeId,
    required this.onSelect,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<Map<String, dynamic>> employees;
  final String emptyMessage;
  final RollCallState Function(int id) stateFor;
  final int? selectedEmployeeId;
  final void Function(Map<String, dynamic> employee)? onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${employees.length}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: employees.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      emptyMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: KioskColors.muted,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: employees.length,
                  itemBuilder: (context, index) {
                    final employee = employees[index];
                    return _RollCallTile(
                      employee: employee,
                      state: stateFor(employee['id'] as int),
                      isSelected: selectedEmployeeId == employee['id'],
                      onSelect: onSelect,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RollCallTile extends StatelessWidget {
  const _RollCallTile({
    required this.employee,
    required this.state,
    required this.isSelected,
    required this.onSelect,
  });

  final Map<String, dynamic> employee;
  final RollCallState state;
  final bool isSelected;
  final void Function(Map<String, dynamic> employee)? onSelect;

  static String _formatPunchTime(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    var hour = local.hour;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    if (hour > 12) hour -= 12;
    if (hour == 0) hour = 12;
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final id = employee['id'] as int;
    final since = state.since;
    final isOvertime = state.status == RollCallStatus.overtime;

    return InkWell(
      // The name is already on screen and the kiosk's next step is always
      // "pick that person", so tapping selects them — the same result as
      // going through the search sheet, minus the typing.
      onTap: onSelect == null ? null : () => onSelect!(employee),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: isSelected
              ? KioskColors.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: employeeAvatarColor(id),
              child: Text(
                employeeInitials(employee),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    employeeDisplayName(employee),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: KioskColors.baseContent,
                    ),
                  ),
                  if (since != null)
                    Text(
                      isOvertime
                          ? 'OT since ${_formatPunchTime(since)}'
                          : 'Since ${_formatPunchTime(since)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isOvertime
                            ? KioskColors.warning
                            : KioskColors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
