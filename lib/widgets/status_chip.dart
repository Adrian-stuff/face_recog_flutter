import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../config/kiosk_config.generated.dart';

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Flattens a translucent fill over an opaque backdrop, so contrast can be
/// measured against the colour a person actually sees rather than against the
/// unblended token.
Color _composite(Color fg, double alpha, Color bg) {
  return Color.fromARGB(
    255,
    ((fg.r * alpha + bg.r * (1 - alpha)) * 255).round(),
    ((fg.g * alpha + bg.g * (1 - alpha)) * 255).round(),
    ((fg.b * alpha + bg.b * (1 - alpha)) * 255).round(),
  );
}

/// Darkens [base] until it is legible on [bg].
///
/// The brand's semantic colours are tuned to sit on white, and every one of
/// them fails WCAG AA as 12px text once it also tints its own background:
/// success lands at 3.8:1, warning 3.4:1, info 2.8:1 against their own chips.
/// The old badges shipped exactly that. Deriving the ink instead of hardcoding
/// four corrected hexes means a fifth state, or a palette change, can't
/// quietly reintroduce the problem — the chip re-solves it at build time.
///
/// The full-strength colour is still what draws the border and the tint, so
/// the state stays readable at a glance from across a room; only the text and
/// icon are darkened.
Color _accessibleInk(Color base, Color bg, {double target = 5.0}) {
  for (var f = 1.0; f >= 0.2; f -= 0.02) {
    final candidate = Color.from(
      alpha: 1.0, red: base.r * f, green: base.g * f, blue: base.b * f,
    );
    if (_contrast(candidate, bg) >= target) return candidate;
  }
  return KioskColors.baseContent;
}

/// One chip shape for every piece of header state.
///
/// Connectivity, updates, sync backlog and permissions each used to build
/// their own container with slightly different padding, radius and opacity —
/// four variations on the same idea sitting side by side, which is what made
/// the header read as cluttered even before it ran out of room. One widget
/// means adding a fifth state later can't drift again.
class StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  /// Swaps the icon for a spinner. Motion here is the state — "checking" and
  /// "up to date" are otherwise a single word apart at a glance.
  final bool busy;

  const StatusChip({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    // Measured against the chip's own blended fill, not the strip behind it,
    // because that fill is what the text actually sits on.
    final fill = _composite(color, 0.10, KioskColors.base200);
    final ink = _accessibleInk(color, fill);

    final chip = Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(KioskRadii.selectorPx),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: busy
                ? CircularProgressIndicator(strokeWidth: 2, color: ink)
                : Icon(icon, color: ink, size: 14),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: ink,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              height: 1.2,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return Center(child: chip);

    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(KioskRadii.selectorPx),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

/// Label/value pair in the version dialog, aligned so the values line up.
class VersionRow extends StatelessWidget {
  final String label;
  final String value;

  const VersionRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: KioskColors.muted),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: KioskColors.baseContent,
            ),
          ),
        ),
      ],
    );
  }
}
