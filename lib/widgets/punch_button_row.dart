import 'package:flutter/material.dart';

/// One punch action: what it says, what it looks like, what it does.
class PunchButtonSpec {
  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback? onPressed;

  const PunchButtonSpec({
    required this.label,
    required this.color,
    required this.icon,
    this.onPressed,
  });
}

/// One or two punch buttons, filling the width they're given.
///
/// Pulled out of FaceScanScreen's private `_buildActionButton` /
/// `_buildBothPunchButtons` / the inline break-row Row so the one genuinely
/// new layout this session introduced — TIME OUT beside START BREAK — could
/// be looked at and overflow-tested without a paired kiosk. FaceScanScreen
/// itself needs a camera and can't be mounted in a plain widget test.
///
/// A single spec fills the row. Two specs split it [primaryFlex]:
/// [secondaryFlex] — weighted 3:2 by default, because the button that ends
/// the day (TIME OUT, or the offline TIME IN/TIME OUT pair) keeps the larger
/// share so the muscle memory for tapping it does not move.
class PunchButtonRow extends StatelessWidget {
  final List<PunchButtonSpec> buttons;
  final int primaryFlex;
  final int secondaryFlex;
  final double gap;

  const PunchButtonRow({
    super.key,
    required this.buttons,
    this.primaryFlex = 3,
    this.secondaryFlex = 2,
    this.gap = 12,
  }) : assert(
         buttons.length == 1 || buttons.length == 2,
         'a punch row is one action or a choice between two, never more',
       );

  @override
  Widget build(BuildContext context) {
    if (buttons.length == 1) return _button(buttons.single);

    final flexes = [primaryFlex, secondaryFlex];
    return Row(
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(flex: flexes[i], child: _button(buttons[i])),
        ],
      ],
    );
  }

  Widget _button(PunchButtonSpec spec) {
    return ElevatedButton.icon(
      onPressed: spec.onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: spec.color,
        padding: const EdgeInsets.symmetric(vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 4,
      ),
      icon: Icon(spec.icon, color: Colors.white, size: 28),
      label: Text(
        spec.label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
