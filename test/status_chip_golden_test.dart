import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/config/kiosk_config.generated.dart';
import 'package:mobile_app/widgets/status_chip.dart';

/// Renders the kiosk header's status strip so the layout can actually be
/// looked at. A kiosk app can't be opened in a browser and its camera/tflite
/// plugins don't run on desktop, so a golden is the only way to see this
/// short of flashing a device.
void main() {
  // Tagged golden: pixel output depends on the host's font rendering and
  // Flutter version, so a mismatch on another machine means "rendered
  // elsewhere", not "regressed". Run it deliberately with
  // `flutter test --tags golden`. The contrast group above is pure maths and
  // stays in the default run, which is where the real regression risk is.
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
  }, tags: 'golden');
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
