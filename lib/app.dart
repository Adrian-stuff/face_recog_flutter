import 'package:flutter/material.dart';
import 'screens/face_scan_screen.dart';
import 'screens/network_setup_screen.dart';
import 'screens/pairing_screen.dart';
import 'widgets/connectivity_banner.dart';
import 'widgets/network_guard.dart';
import 'services/provisioning_service.dart';
import 'services/supabase_service.dart';
import 'services/update_service.dart';

class FaceAttendanceApp extends StatefulWidget {
  const FaceAttendanceApp({super.key});

  @override
  State<FaceAttendanceApp> createState() => _FaceAttendanceAppState();
}

class _FaceAttendanceAppState extends State<FaceAttendanceApp> {
  bool _updateReady = false;

  @override
  void initState() {
    super.initState();
    _checkForPendingUpdate();
  }

  Future<void> _checkForPendingUpdate() async {
    // After the fire-and-forget in main.dart finishes, check once more
    // to decide whether to show the restart banner.
    final updated = await UpdateService.instance.checkAndUpdate();
    if (updated && mounted) {
      setState(() => _updateReady = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      builder: (context, child) {
        return Column(
          children: [
            // Only meaningful once provisioned and syncing — during
            // pairing/network-setup nothing updates connectivityStatus (it's
            // only touched by the sync machinery FaceScanScreen starts), and
            // those screens already run their own pingServer()-driven UI
            // this would otherwise talk over.
            ValueListenableBuilder<ProvisioningState>(
              valueListenable: ProvisioningService.instance.state,
              builder: (context, provisioningState, _) {
                if (provisioningState != ProvisioningState.ready) {
                  return const SizedBox.shrink();
                }
                return ValueListenableBuilder<ConnectivityStatus>(
                  valueListenable: SupabaseService().connectivityStatus,
                  builder: (context, status, _) {
                    if (status == ConnectivityStatus.online) {
                      return const SizedBox.shrink();
                    }
                    return ConnectivityBanner(status: status);
                  },
                );
              },
            ),
            if (_updateReady)
              MaterialBanner(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                content: const Text(
                  'A new update has been downloaded. '
                  'Restart the app to apply it.',
                ),
                leading: const Icon(Icons.system_update, color: Colors.blue),
                backgroundColor: Colors.blue.shade50,
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _updateReady = false),
                    child: const Text('DISMISS'),
                  ),
                ],
              ),
            Expanded(child: child ?? const SizedBox.shrink()),
          ],
        );
      },
      // Gates the kiosk on this device being bound to exactly one company.
      // Listens rather than checking once, so a mismatch discovered by a
      // background ping mid-shift swaps the UI immediately instead of
      // leaving a scan screen up that can no longer record anything.
      home: ValueListenableBuilder<ProvisioningState>(
        valueListenable: ProvisioningService.instance.state,
        builder: (context, state, _) {
          switch (state) {
            case ProvisioningState.unprovisioned:
              return const PairingScreen();
            case ProvisioningState.companyMismatch:
              return const PairingScreen(isRebind: true);
            case ProvisioningState.needsNetworkSetup:
              return const NetworkSetupScreen();
            case ProvisioningState.ready:
              return const NetworkGuard(child: FaceScanScreen());
          }
        },
      ),
    );
  }
}
