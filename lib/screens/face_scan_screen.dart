import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:table_calendar/table_calendar.dart';
import '../services/face_service.dart';
import '../services/sound_service.dart';
import '../services/supabase_service.dart';
import '../widgets/real_time_clock.dart';
import '../widgets/weather_widget.dart';
import 'liveness_check_screen.dart';
import 'registration_screen.dart';

class FaceScanScreen extends StatefulWidget {
  const FaceScanScreen({super.key});

  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

class _FaceScanScreenState extends State<FaceScanScreen> {
  final SupabaseService _supabaseService = SupabaseService();
  final FaceService _faceService = FaceService();
  final SoundService _soundService = SoundService();

  bool _isProcessing = false;
  String _statusMessage = "Loading...";
  bool _isConnected = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Calendar state
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
    _initialize();
  }

  void _initConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (mounted) setState(() => _isConnected = isConnected);
    });
  }

  Future<void> _initialize() async {
    // Request permissions upfront
    await [Permission.camera, Permission.location].request();

    // Pre-warm FaceService (loads TFLite model)
    try {
      await _faceService.initialize();
      await _soundService.initialize();
      if (mounted) setState(() => _statusMessage = "Ready");
    } catch (e) {
      debugPrint("FaceService init error: $e");
      if (mounted) setState(() => _statusMessage = "Service Error");
    }

    // Trigger background sync
    _supabaseService.syncEmployees();
    _supabaseService.syncLogs();
  }

  Future<void> _recordAttendance(String type) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = "Opening liveness check...";
    });

    try {
      // Navigate to LivenessCheckScreen — returns photo path on success.
      final photoPath = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (_) => const LivenessCheckScreen()),
      );

      if (!mounted) return;

      if (photoPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Liveness check cancelled."),
            backgroundColor: Colors.orange,
          ),
        );
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
        return;
      }

      setState(() => _statusMessage = "Verifying identity...");

      // Generate embedding from photo.
      final embedding = await _faceService.getFaceEmbeddingFromFile(photoPath);
      if (embedding == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Could not extract face. Try again."),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
        return;
      }

      // Verify face.
      final matchedEmployee = await _supabaseService.verifyFace(embedding);
      if (matchedEmployee == null) {
        
        await _soundService.playError(message: "Face not recognized");

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Face not recognized."),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
        return;
      }

      // Record attendance.
      final employeeId = matchedEmployee['id'] as int;
      final firstName = matchedEmployee['first_name'] ?? '';
      final lastName = matchedEmployee['last_name'] ?? '';
      final similarity = matchedEmployee['similarity'];

      await _supabaseService.recordAttendance(employeeId, type);

      // Play Success Sound
      await _soundService.playSuccess(
        message: "${type == 'time-in' ? 'Time In' : 'Time Out'} recorded",
      );

      if (mounted) {
        final action = type == 'time-in' ? 'Time In' : 'Time Out';
        final now = DateTime.now();
        // Simple formatting to avoid intl dependency if not already imported,
        // but since we added intl earlier for calendar, we can use it.
        // Or just basic string manip to be safe/quick.
        final timeString =
            "${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}";

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$action recorded for $firstName $lastName at $timeString\n'
              'Match: ${(similarity * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 16),
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // Clean up the error message
        String errorMessage = e.toString().replaceAll('Exception: ', '');
        
        await _soundService.playError(message: "Error: $errorMessage");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
      }
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _showAdminLoginDialog() async {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Admin Login"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: "Email"),
              keyboardType: TextInputType.emailAddress,
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: "Password"),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = emailController.text;
              final password = passwordController.text;

              Navigator.pop(dialogContext);

              final success = await _supabaseService.loginAdmin(
                email,
                password,
              );

              if (mounted) {
                if (success) {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RegistrationScreen(),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Invalid Credentials"),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text("Login"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Face Attendance"),
        centerTitle: true,
        actions: [
          // Internet Status Indicator
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _isConnected
                  ? Colors.green.withOpacity(0.1)
                  : Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isConnected ? Colors.green : Colors.red,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isConnected ? Icons.wifi : Icons.wifi_off,
                  color: _isConnected ? Colors.green : Colors.red,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  _isConnected ? "Online" : "Offline",
                  style: TextStyle(
                    color: _isConnected ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: _showAdminLoginDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Date & Time
                    const Center(child: RealTimeClock()),
                    const SizedBox(height: 20),

                    // 2. Weather Widget
                    const WeatherWidget(),
                    const SizedBox(height: 20),

                    // 3. Status Display
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withOpacity(0.3)),
                      ),
                      child: Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 4. Calendar
                    Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TableCalendar(
                          firstDay: DateTime.utc(2020, 1, 1),
                          lastDay: DateTime.utc(2030, 12, 31),
                          focusedDay: _focusedDay,
                          calendarFormat: _calendarFormat,
                          selectedDayPredicate: (day) {
                            return isSameDay(_selectedDay, day);
                          },
                          onDaySelected: (selectedDay, focusedDay) {
                            if (!isSameDay(_selectedDay, selectedDay)) {
                              setState(() {
                                _selectedDay = selectedDay;
                                _focusedDay = focusedDay;
                              });
                            }
                          },
                          onFormatChanged: (format) {
                            if (_calendarFormat != format) {
                              setState(() {
                                _calendarFormat = format;
                              });
                            }
                          },
                          onPageChanged: (focusedDay) {
                            _focusedDay = focusedDay;
                          },
                          headerStyle: const HeaderStyle(
                            formatButtonVisible: false,
                            titleCentered: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 5. Action Buttons (Sticky at bottom)
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildActionButton(
                      label: "TIME IN",
                      color: Colors.green,
                      icon: Icons.login,
                      onPressed: _isProcessing
                          ? null
                          : () => _recordAttendance('time-in'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildActionButton(
                      label: "TIME OUT",
                      color: Colors.orange,
                      icon: Icons.logout,
                      onPressed: _isProcessing
                          ? null
                          : () => _recordAttendance('time-out'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required Color color,
    required IconData icon,
    VoidCallback? onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        padding: const EdgeInsets.symmetric(vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 4,
      ),
      icon: Icon(icon, color: Colors.white, size: 28),
      label: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
