import 'package:flutter/material.dart';
import 'screens/face_scan_screen.dart';
import 'widgets/network_guard.dart';

class FaceAttendanceApp extends StatelessWidget {
  const FaceAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const NetworkGuard(child: FaceScanScreen()),
    );
  }
}
