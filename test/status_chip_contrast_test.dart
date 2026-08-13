import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/config/kiosk_config.generated.dart';
import 'package:mobile_app/widgets/status_chip.dart';

/// The chip derives its own text colour rather than using the raw semantic
/// token, because every one of those tokens fails WCAG AA at 12px once it
/// also tints its own background. This pins that down: it is the exact
/// regression the previous hand-rolled badges shipped, and it is invisible
/// in a screenshot.
void main() {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  double contrast(Color a, Color b) {
    final la = luminance(a), lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  const semantic = {
    'success': KioskColors.success,
    'warning': KioskColors.warning,
    'error': KioskColors.error,
    'info': KioskColors.info,
    'muted': KioskColors.muted,
  };

  group('StatusChip contrast', () {
    semantic.forEach((name, color) {
      testWidgets('$name label meets WCAG AA on its own chip fill', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: KioskColors.base200,
              body: Center(
                child: StatusChip(icon: Icons.wifi, label: 'Sample', color: color),
              ),
            ),
          ),
        );

        final fill = Color.from(
          alpha: 1.0,
          red: color.r * 0.10 + KioskColors.base200.r * 0.90,
          green: color.g * 0.10 + KioskColors.base200.g * 0.90,
          blue: color.b * 0.10 + KioskColors.base200.b * 0.90,
        );

        final text = tester.widget<Text>(find.text('Sample'));
        final ink = text.style!.color!;

        // 4.5:1 is the AA floor for text this size; the widget aims for 5.0
        // so a palette tweak has room to move before it breaks.
        expect(
          contrast(ink, fill),
          greaterThanOrEqualTo(4.5),
          reason: '$name ink ${ink.toARGB32().toRadixString(16)} on chip fill '
              '${fill.toARGB32().toRadixString(16)} is unreadable at 12px',
        );

        // The untouched token still draws the border/tint, which only has to
        // clear the 3:1 bar for non-text.
        expect(contrast(color, KioskColors.base200), greaterThanOrEqualTo(3.0),
            reason: '$name border is invisible against the strip');
      });
    });
  });
}
