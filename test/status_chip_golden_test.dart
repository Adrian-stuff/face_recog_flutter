import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:math' as math;

import 'package:mobile_app/config/kiosk_config.generated.dart';
import 'package:mobile_app/widgets/status_chip.dart';

/// Renders the kiosk header's status strip so the layout can actually be
/// looked at. A kiosk app can't be opened in a browser and its camera/tflite
/// plugins don't run on desktop, so a golden is the only way to see this
/// short of flashing a device.
void main() {
  _contrastTests();
  testWidgets('status strip renders every state without overflowing', (
    tester,
  ) async {
    // Deliberately every chip at once — the row is widest when connectivity,
    // updates, sync backlog and permissions are all reporting at the same
    // time, which is exactly the state the old AppBar ran out of room in.
    await tester.binding.setSurfaceSize(const Size(900, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _strip(const [
                StatusChip(
                  icon: Icons.wifi,
                  label: 'Online',
                  color: KioskColors.success,
                ),
                StatusChip(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Up to date',
                  color: KioskColors.success,
                ),
              ]),
              const SizedBox(height: 12),
              _strip(const [
                StatusChip(
                  icon: Icons.wifi,
                  label: 'Online',
                  color: KioskColors.success,
                ),
                StatusChip(
                  icon: Icons.cloud_sync,
                  label: 'Updating…',
                  color: KioskColors.info,
                  busy: true,
                ),
              ]),
              const SizedBox(height: 12),
              _strip(const [
                StatusChip(
                  icon: Icons.wifi_off,
                  label: 'Offline',
                  color: KioskColors.error,
                ),
                StatusChip(
                  icon: Icons.system_update,
                  label: 'Restart to update',
                  color: KioskColors.warning,
                ),
                StatusChip(
                  icon: Icons.cloud_upload_outlined,
                  label: '3 pending',
                  color: KioskColors.warning,
                ),
                StatusChip(
                  icon: Icons.no_accounts,
                  label: '2 permissions off',
                  color: KioskColors.error,
                ),
              ]),
            ],
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 100));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/status_strip.png'),
    );
  });
}

Widget _strip(List<Widget> chips) {
  return Container(
    height: 44,
    width: double.infinity,
    decoration: const BoxDecoration(
      color: KioskColors.base200,
      border: Border(
        top: BorderSide(color: KioskColors.hairline),
        bottom: BorderSide(color: KioskColors.hairline),
      ),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: chips),
    ),
  );
}

/// The chip derives its own text colour rather than using the raw semantic
/// token, because every one of those tokens fails WCAG AA at 12px once it
/// also tints its own background. This pins that down: it is the exact
/// regression the previous hand-rolled badges shipped, and it is invisible
/// in a screenshot.
void _contrastTests() {
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
