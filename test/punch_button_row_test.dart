import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/punch_button_row.dart';

/// The one genuinely new layout this session introduced: TIME OUT beside
/// START BREAK, unevenly split. FaceScanScreen itself needs a camera and
/// can't be mounted in a widget test, so the split-row logic was pulled out
/// of it into this pure widget — the only way to actually look at (and
/// overflow-test) the layout without a paired kiosk.
///
/// Checked at 280-430px width and up to 2.0x text scale (Android's actual
/// accessibility maximum) before writing these assertions, not after: no
/// overflow anywhere in that range, so this is a plain regression pin, not a
/// defensive one.
void main() {
  Widget harness(Widget child, {double width = 430, double textScale = 1.0}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 900),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
      ),
    );
  }

  final timeOutBreak = PunchButtonRow(
    buttons: [
      PunchButtonSpec(label: 'TIME OUT', color: Colors.orange, icon: Icons.logout, onPressed: () {}),
      PunchButtonSpec(label: 'START BREAK', color: Colors.purple, icon: Icons.wb_sunny, onPressed: () {}),
    ],
  );

  final bothOffline = PunchButtonRow(
    primaryFlex: 1,
    secondaryFlex: 1,
    gap: 16,
    buttons: [
      PunchButtonSpec(label: 'TIME IN', color: Colors.green, icon: Icons.login, onPressed: () {}),
      PunchButtonSpec(label: 'TIME OUT', color: Colors.orange, icon: Icons.logout, onPressed: () {}),
    ],
  );

  group('one button', () {
    testWidgets('fills the row rather than splitting for nothing', (tester) async {
      await tester.pumpWidget(harness(PunchButtonRow(
        buttons: [PunchButtonSpec(label: 'ALL DONE FOR TODAY', color: Colors.grey, icon: Icons.check, onPressed: null)],
      )));
      // ElevatedButton.icon uses a Row internally regardless, so Expanded
      // is what actually distinguishes "split between two" from "one button
      // filling the space" — only the two-button path introduces it.
      expect(find.byType(Expanded), findsNothing);
      expect(find.text('ALL DONE FOR TODAY'), findsOneWidget);
    });
  });

  group('the mid-shift split — TIME OUT (3) / START BREAK (2)', () {
    for (final w in [430.0, 400.0, 375.0, 360.0, 320.0, 280.0]) {
      testWidgets('renders without overflow at ${w}px', (tester) async {
        await tester.pumpWidget(harness(timeOutBreak, width: w));
        expect(tester.takeException(), isNull);
      });
    }

    for (final scale in [1.0, 1.15, 1.3, 1.5, 2.0]) {
      testWidgets('renders without overflow at ${scale}x text scale', (tester) async {
        await tester.pumpWidget(harness(timeOutBreak, textScale: scale));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('both labels are on screen, not truncated away', (tester) async {
      await tester.pumpWidget(harness(timeOutBreak));
      expect(find.text('TIME OUT'), findsOneWidget);
      expect(find.text('START BREAK'), findsOneWidget);
    });

    testWidgets('taps the button under the finger, not its neighbour', (tester) async {
      var tappedBreak = false;
      await tester.pumpWidget(harness(PunchButtonRow(buttons: [
        PunchButtonSpec(label: 'TIME OUT', color: Colors.orange, icon: Icons.logout, onPressed: () {}),
        PunchButtonSpec(label: 'START BREAK', color: Colors.purple, icon: Icons.wb_sunny, onPressed: () => tappedBreak = true),
      ])));
      await tester.tap(find.text('START BREAK'));
      expect(tappedBreak, isTrue);
    });
  });

  group('the offline fallback — TIME IN / TIME OUT, even split', () {
    testWidgets('renders without overflow at kiosk width', (tester) async {
      await tester.pumpWidget(harness(bothOffline));
      expect(tester.takeException(), isNull);
      expect(find.text('TIME IN'), findsOneWidget);
      expect(find.text('TIME OUT'), findsOneWidget);
    });
  });

  testWidgets('a null onPressed disables the button rather than crashing', (tester) async {
    await tester.pumpWidget(harness(PunchButtonRow(buttons: [
      PunchButtonSpec(label: 'CHECKING STATUS…', color: Colors.grey, icon: Icons.access_time, onPressed: null),
    ])));
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
  });
}
