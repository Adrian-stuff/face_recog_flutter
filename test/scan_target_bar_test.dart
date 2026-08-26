import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/scan_target_bar.dart';

/// This bar is the kiosk's answer to "whose attendance is this button about
/// to write?". Getting it wrong doesn't look wrong — it records a real punch
/// against the wrong person — so the name and the shift state are worth
/// pinning down.

const _ana = <String, dynamic>{
  'id': 1,
  'first_name': 'Ana',
  'last_name': 'Cruz',
  'position': 'Machinist',
};

Future<void> _pump(
  WidgetTester tester, {
  Map<String, dynamic>? employee = _ana,
  String? nextAction = 'time-in',
  bool isLoadingNextAction = false,
  VoidCallback? onChange,
  VoidCallback? onSelect,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ScanTargetBar(
          employee: employee,
          nextAction: nextAction,
          isLoadingNextAction: isLoadingNextAction,
          onChange: onChange ?? () {},
          onSelect: onSelect ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  group('shiftStateDisplay', () {
    test('names the state for every action the punch buttons can offer', () {
      expect(shiftStateDisplay('time-in').label, 'Ready to time in');
      expect(shiftStateDisplay('time-out').label, 'On the clock');
      expect(shiftStateDisplay('overtime-in').label, contains('OVERTIME'));
      expect(shiftStateDisplay('overtime-out').label, 'Overtime active');
      expect(shiftStateDisplay('done').label, 'All done for today');
    });

    // A null action is the offline/unknown case, which still shows both
    // punch buttons — so this has to read as usable, not as an error.
    test('falls back to a usable label when the action is unknown', () {
      expect(shiftStateDisplay(null).label, 'Ready to verify');
      expect(shiftStateDisplay('something-new').label, 'Ready to verify');
    });

    test('gives overtime its own colour, distinct from a regular punch', () {
      expect(
        shiftStateDisplay('overtime-in').color,
        isNot(shiftStateDisplay('time-in').color),
      );
      expect(
        shiftStateDisplay('overtime-out').color,
        isNot(shiftStateDisplay('time-out').color),
      );
    });
  });

  group('ScanTargetBar', () {
    testWidgets('names who the punch is for', (tester) async {
      await _pump(tester);

      expect(find.text('SCANNING FOR'), findsOneWidget);
      expect(find.text('Ana Cruz'), findsOneWidget);
      expect(find.text('Ready to time in'), findsOneWidget);
    });

    testWidgets('prompts instead of naming anyone when nothing is selected', (
      tester,
    ) async {
      await _pump(tester, employee: null);

      expect(find.text('SCANNING FOR'), findsNothing);
      expect(
        find.text('Tap your name above, or search the roster'),
        findsOneWidget,
      );
    });

    testWidgets('the prompt opens the selector', (tester) async {
      var opened = false;
      await _pump(tester, employee: null, onSelect: () => opened = true);

      await tester.tap(find.text('Tap your name above, or search the roster'));
      await tester.pump();

      expect(opened, isTrue);
    });

    testWidgets('Change reopens the selector', (tester) async {
      var changed = false;
      await _pump(tester, onChange: () => changed = true);

      await tester.tap(find.text('Change'));
      await tester.pump();

      expect(changed, isTrue);
    });

    testWidgets('says it is still checking rather than guessing a state', (
      tester,
    ) async {
      await _pump(tester, isLoadingNextAction: true, nextAction: null);

      expect(find.text('Checking status…'), findsOneWidget);
      // Must not fall back to the "Ready to verify" default while the real
      // answer is still in flight.
      expect(find.text('Ready to verify'), findsNothing);
    });

    testWidgets('spells out that an overtime punch is overtime', (
      tester,
    ) async {
      await _pump(tester, nextAction: 'overtime-in');

      expect(find.textContaining('OVERTIME'), findsOneWidget);
    });

    testWidgets('a long name stays on one line rather than breaking layout', (
      tester,
    ) async {
      await _pump(
        tester,
        employee: const {
          'id': 5,
          'first_name': 'Elena',
          'last_name': 'Villanueva-Bautista',
        },
      );

      final name = tester.widget<Text>(
        find.text('Elena Villanueva-Bautista'),
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    // The screen passes null for both callbacks while a scan is running.
    testWidgets('both controls go inert while a scan is in flight', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ScanTargetBar(
              employee: _ana,
              nextAction: 'time-in',
              isLoadingNextAction: false,
              onChange: null,
              onSelect: null,
            ),
          ),
        ),
      );

      final change = tester.widget<TextButton>(
        find.ancestor(of: find.text('Change'), matching: find.byType(TextButton)),
      );
      expect(change.onPressed, isNull);
    });
  });
}
