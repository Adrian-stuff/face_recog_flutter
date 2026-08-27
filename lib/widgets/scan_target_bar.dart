import 'package:flutter/material.dart';

import '../config/kiosk_config.generated.dart';
import '../utils/employee_display.dart';
import 'employee_avatar.dart';

/// How a shift state should read on screen.
typedef ShiftStateDisplay = ({IconData icon, String label, Color color});

/// The employee's current shift state, phrased as what happens next.
///
/// Keyed off the same `nextAction` string the punch buttons are driven by, so
/// the line above the button and the button itself can never disagree about
/// what is about to be recorded.
///
/// Kept short on purpose. This sits on one line beside a 52px avatar and a
/// Change button, and the longer phrasings ellipsised away their own last
/// word — "Regular shift done — starting OVER…" being the worst of them,
/// since OVERTIME is the part that needed saying. The button underneath
/// already names the action, so this only has to carry the state.
ShiftStateDisplay shiftStateDisplay(String? nextAction) => switch (nextAction) {
  'time-in' => (
    icon: Icons.login_rounded,
    label: 'Ready to time in',
    color: KioskColors.success,
  ),
  'time-out' => (
    icon: Icons.access_time_rounded,
    label: 'On the clock',
    color: KioskColors.warning,
  ),
  // Breaks reuse glyphs the shipped release already bundles. A patch carries
  // no assets, so an icon outside that set renders as an empty box on every
  // kiosk while looking perfect locally — there is no coffee cup in the 84
  // glyphs release 1.2.0+67 tree-shook down to.
  'break-out' => (
    icon: Icons.wb_sunny,
    label: 'On the clock — can take a break',
    color: KioskColors.warning,
  ),
  'break-in' => (
    icon: Icons.wb_sunny,
    label: 'On a break',
    color: Color(0xFF6A4CB8),
  ),
  'overtime-in' => (
    icon: Icons.more_time_rounded,
    label: 'Shift done — this is OVERTIME',
    color: Color(0xFF00897B),
  ),
  'overtime-out' => (
    icon: Icons.timelapse_rounded,
    label: 'Overtime active',
    color: Color(0xFFE65100),
  ),
  'done' => (
    icon: Icons.check_circle_outline_rounded,
    label: 'All done for today',
    color: KioskColors.muted,
  ),
  _ => (
    icon: Icons.verified_rounded,
    label: 'Ready to verify',
    color: KioskColors.success,
  ),
};

/// Who the punch buttons are about to record for.
///
/// Lives pinned to the action bar rather than in the scrolling body above it.
/// The identity card used to sit near the top of the page, so by the time
/// someone had scrolled down to the button that acts on it, nothing on screen
/// said whose attendance was about to be written — and on a shared kiosk the
/// person selected is quite often not the person now standing at it.
class ScanTargetBar extends StatelessWidget {
  const ScanTargetBar({
    super.key,
    required this.employee,
    required this.nextAction,
    required this.isLoadingNextAction,
    required this.onChange,
    required this.onSelect,
  });

  /// Null when nobody has been picked yet, which turns this into the prompt.
  final Map<String, dynamic>? employee;

  /// `'time-in'|'time-out'|'overtime-in'|'overtime-out'|'done'`, or null when
  /// the state could not be determined.
  final String? nextAction;
  final bool isLoadingNextAction;

  /// Null while a scan is in flight, which disables swapping the employee out
  /// from under the punch being recorded.
  final VoidCallback? onChange;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = employee;
    if (selected == null) return _prompt();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: KioskColors.base200,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KioskColors.hairline),
      ),
      child: Row(
        children: [
          // Same tag as the selector sheet's avatar, so picking a name flies
          // the face down here instead of cutting to it.
          Hero(
            tag: 'employee_avatar_${selected['id']}',
            child: EmployeeAvatar(employee: selected, size: 52),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SCANNING FOR',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: KioskColors.muted,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  employeeDisplayName(selected),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    color: KioskColors.baseContent,
                  ),
                ),
                const SizedBox(height: 3),
                _shiftState(),
              ],
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(
              foregroundColor: KioskColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Change',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _prompt() {
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: KioskColors.base200,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: KioskColors.hairline),
        ),
        child: Row(
          children: [
            Icon(
              Icons.person_search_rounded,
              size: 26,
              color: KioskColors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Tap your name above, or search the roster',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: KioskColors.muted,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 16,
              color: KioskColors.muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _shiftState() {
    if (isLoadingNextAction) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: KioskColors.muted,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Checking status…',
            style: TextStyle(fontSize: 12, color: KioskColors.muted),
          ),
        ],
      );
    }

    final display = shiftStateDisplay(nextAction);
    // Overtime is the most consequential punch the kiosk can record and the
    // one most often taken by mistake, so it gets a bordered pill rather
    // than the same quiet row as everything else.
    final isOvertime =
        nextAction == 'overtime-in' || nextAction == 'overtime-out';

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(display.icon, size: 13, color: display.color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            display.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: display.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    if (!isOvertime) return row;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: display.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: display.color.withValues(alpha: 0.4)),
      ),
      child: row,
    );
  }
}
