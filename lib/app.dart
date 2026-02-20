import 'package:flutter/material.dart';
import 'screens/face_scan_screen.dart';
import 'widgets/network_guard.dart';
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
      home: const NetworkGuard(child: FaceScanScreen()),
    );
  }
}
