import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/roll_call_panel.dart';

/// The roll call is the only thing on the scan screen that reports on people
/// who aren't standing at it, so a name in the wrong column is a wrong answer
/// to "has so-and-so come in yet?" rather than a cosmetic slip.

const _employees = <Map<String, dynamic>>[
  {'id': 1, 'first_name': 'Ana', 'last_name': 'Cruz'},
  {'id': 2, 'first_name': 'Ben', 'last_name': 'Santos'},
  {'id': 3, 'first_name': 'Carla', 'last_name': 'Mendoza'},
  {'id': 4, 'first_name': 'Diego', 'last_name': 'Ramos'},
  {'id': 5, 'first_name': 'Elena', 'last_name': 'Reyes'},
];

String _at(int hour, int minute) =>
    DateTime(2026, 8, 21, hour, minute).toIso8601String();

Future<void> _pump(
  WidgetTester tester, {
  required Map<int, Map<String, String>> punches,
  int? selectedEmployeeId,
  void Function(Map<String, dynamic>)? onSelect,
  List<Map<String, dynamic>> employees = _employees,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RollCallPanel(
          employees: employees,
          punches: punches,
          selectedEmployeeId: selectedEmployeeId,
          onSelect: onSelect,
        ),
      ),
    ),
  );
}

bool _insideAvatar(Element element) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is CircleAvatar) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// The text rendered under one column heading, in order — each employee's
/// name followed by their "since" line, where they have one.
List<String> _namesUnder(WidgetTester tester, String heading) {
  final column = find
      .ancestor(of: find.text(heading), matching: find.byType(Column))
      .first;

  return find
      .descendant(of: column, matching: find.byType(Text))
      .evaluate()
      // Initials are Text too, but they live inside the avatar circle.
      .where((element) => !_insideAvatar(element))
      .map((element) => (element.widget as Text).data ?? '')
      // Drop the heading itself and its count badge.
      .where((label) => label != heading && int.tryParse(label) == null)
      .toList();
}

void main() {
  group('rollCallStateFor', () {
    test('no punches at all reads as not timed in', () {
      expect(rollCallStateFor(const {}).status, RollCallStatus.notIn);
      expect(rollCallStateFor(const {}).since, isNull);
    });

    test('time-in with no time-out is on the clock, since the time-in', () {
      final state = rollCallStateFor({'time-in': _at(8, 0)});
      expect(state.status, RollCallStatus.onTheClock);
      expect(state.since, _at(8, 0));
    });

    test('both regular punches and no overtime reads as done', () {
      final state = rollCallStateFor({
        'time-in': _at(8, 0),
        'time-out': _at(17, 0),
      });
      expect(state.status, RollCallStatus.done);
      expect(state.since, isNull);
    });

    // The case that makes this more than a two-way split: someone in
    // overtime has a time-out on record but is still working, and must not
    // read as finished for the day.
    test('an open overtime session counts as still on the clock', () {
      final state = rollCallStateFor({
        'time-in': _at(8, 0),
        'time-out': _at(17, 0),
        'overtime-in': _at(17, 30),
      });
      expect(state.status, RollCallStatus.overtime);
      expect(state.since, _at(17, 30));
    });

    test('a closed overtime session reads as done', () {
      final state = rollCallStateFor({
        'time-in': _at(8, 0),
        'time-out': _at(17, 0),
        'overtime-in': _at(17, 30),
        'overtime-out': _at(20, 0),
      });
      expect(state.status, RollCallStatus.done);
    });
  });

  group('RollCallPanel', () {
    testWidgets('sorts each employee into the column their day puts them in', (
      tester,
    ) async {
      await _pump(
        tester,
        punches: {
          2: {'time-in': _at(7, 58)},
          3: {'time-in': _at(8, 1), 'time-out': _at(17, 3)},
          4: {
            'time-in': _at(7, 45),
            'time-out': _at(16, 30),
            'overtime-in': _at(17, 15),
          },
        },
      );

      // Ana (nothing) and Elena (nothing) still owe a time-in.
      expect(_namesUnder(tester, 'Not timed in'), ['Ana Cruz', 'Elena Reyes']);
      // Ben is mid-shift; Diego is in overtime, which is still on the clock.
      expect(_namesUnder(tester, 'Still timed in'), [
        'Ben Santos',
        'Since 7:58 AM',
        'Diego Ramos',
        'OT since 5:15 PM',
      ]);
    });

    testWidgets('counts the finished employees in the footer', (tester) async {
      await _pump(
        tester,
        punches: {
          2: {'time-in': _at(8, 0), 'time-out': _at(17, 0)},
          3: {'time-in': _at(8, 0), 'time-out': _at(17, 0)},
        },
      );

      expect(
        find.text('2 finished for the day · punches recorded on this device'),
        findsOneWidget,
      );
    });

    testWidgets('drops the finished count when nobody has finished', (
      tester,
    ) async {
      await _pump(tester, punches: const {});

      expect(find.text('Punches recorded on this device'), findsOneWidget);
    });

    testWidgets('reports each column headcount beside its heading', (
      tester,
    ) async {
      await _pump(
        tester,
        punches: {
          2: {'time-in': _at(7, 58)},
          3: {'time-in': _at(8, 1), 'time-out': _at(17, 3)},
        },
      );

      // 3 with no time-in, 1 on the clock.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('tapping a name hands that employee back to the caller', (
      tester,
    ) async {
      Map<String, dynamic>? selected;
      await _pump(
        tester,
        punches: const {},
        onSelect: (employee) => selected = employee,
      );

      await tester.tap(find.text('Carla Mendoza'));
      await tester.pump();

      expect(selected, isNotNull);
      expect(selected!['id'], 3);
    });

    // Guards the scan-in-flight case: the screen passes a null onSelect while
    // recording, and a tap landing then would swap the employee out from
    // under the punch being written.
    testWidgets('a null onSelect makes the rows inert', (tester) async {
      await _pump(tester, punches: const {}, onSelect: null);

      final inkWell = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.text('Carla Mendoza'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(inkWell.onTap, isNull);
    });

    testWidgets('an empty roster says so rather than showing a bare column', (
      tester,
    ) async {
      await _pump(tester, punches: const {}, employees: const []);

      expect(find.text('No employees yet.'), findsOneWidget);
      expect(find.text('Nobody is on the clock.'), findsOneWidget);
    });

    testWidgets('says everyone is in once the first column empties', (
      tester,
    ) async {
      await _pump(
        tester,
        punches: {
          for (var id = 1; id <= 5; id++) id: {'time-in': _at(8, 0)},
        },
      );

      expect(find.text('Everyone has timed in.'), findsOneWidget);
    });
  });
}
