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
import '../widgets/searchable_employee_selector.dart';
import 'liveness_check_screen.dart';
import 'admin_dashboard_screen.dart';

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

  // Employee selection state
  List<Map<String, dynamic>> _employees = [];
  Map<String, dynamic>? _selectedEmployee;
  bool _isLoadingEmployees = true;

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

    // Load employees for selector
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    setState(() => _isLoadingEmployees = true);
    try {
      final employees = await _supabaseService.fetchEmployeesWithPhotos();
      if (mounted) {
        setState(() {
          _employees = employees;
          _isLoadingEmployees = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading employees: $e');
      if (mounted) {
        setState(() => _isLoadingEmployees = false);
      }
    }
  }

  void _openEmployeeSelector() async {
    final selected = await SearchableEmployeeSelector.show(context, _employees);
    if (selected != null && mounted) {
      setState(() => _selectedEmployee = selected);
    }
  }

  Future<void> _recordAttendance(String type) async {
    if (_isProcessing) return;

    // Require employee selection
    if (_selectedEmployee == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.person_search, color: Colors.white),
              SizedBox(width: 8),
              Text("Please select an employee first"),
            ],
          ),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      return;
    }

    final employeeId = _selectedEmployee!['id'] as int;
    final firstName = _selectedEmployee!['first_name'] ?? '';
    final lastName = _selectedEmployee!['last_name'] ?? '';

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

      // Verify face against the SELECTED employee (all their encodings)
      setState(
        () => _statusMessage = "Matching face against $firstName $lastName...",
      );

      final matchResult = await _supabaseService.verifyFaceAgainstEmployee(
        embedding,
        employeeId,
      );

      if (matchResult == null) {
        await _soundService.playError(
          message: "Face does not match $firstName $lastName",
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Colors.white),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Face does not match the selected employee. Please try again or select the correct employee.",
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 5),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
        return;
      }

      // Face matched! Record attendance + improve dataset
      final similarity = matchResult['similarity'];

      // Improve Dataset (Fire & Forget)
      if (_isConnected) {
        _supabaseService
            .saveFaceDescriptor(employeeId, embedding)
            .then((_) {
              debugPrint("Dataset improved for employee $employeeId");
            })
            .catchError((e) {
              debugPrint("Failed to improve dataset (non-fatal): $e");
            });
      }

      // Record Attendance
      await _supabaseService.recordAttendance(employeeId, type);

      // Play Success Sound
      await _soundService.playSuccess(
        message: "${type == 'time-in' ? 'Time In' : 'Time Out'} recorded",
      );

      if (mounted) {
        final action = type == 'time-in' ? 'Time In' : 'Time Out';
        final now = DateTime.now();
        final timeString =
            "${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}";

        // Show success dialog
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 56,
                    color: Colors.green.shade600,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '$action Recorded!',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$firstName $lastName',
                  style: TextStyle(
                    fontSize: 17,
                    color: Colors.grey[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  timeString,
                  style: TextStyle(fontSize: 15, color: Colors.grey[500]),
                ),
                const SizedBox(height: 4),
                Text(
                  'Match: ${(similarity * 100).toStringAsFixed(1)}%',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                ),
              ],
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        );

        // Clear selection after successful recording
        setState(() => _selectedEmployee = null);
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
                      builder: (_) => const AdminDashboardScreen(),
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

  Color _getAvatarColor(int id) {
    final colors = [
      const Color(0xFF1E88E5),
      const Color(0xFF43A047),
      const Color(0xFF8E24AA),
      const Color(0xFFE53935),
      const Color(0xFFFB8C00),
      const Color(0xFF00ACC1),
      const Color(0xFF3949AB),
      const Color(0xFF7CB342),
    ];
    return colors[id % colors.length];
  }

  String _getInitials(Map<String, dynamic> emp) {
    final first = (emp['first_name'] ?? '').toString();
    final last = (emp['last_name'] ?? '').toString();
    String initials = '';
    if (first.isNotEmpty) initials += first[0].toUpperCase();
    if (last.isNotEmpty) initials += last[0].toUpperCase();
    return initials.isEmpty ? '?' : initials;
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

                    // 4. Employee Selector Card
                    _buildEmployeeSelectorCard(),
                    const SizedBox(height: 20),

                    // 5. Calendar
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

            // 6. Action Buttons (Sticky at bottom)
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
                      color: _selectedEmployee != null
                          ? Colors.green
                          : Colors.grey,
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
                      color: _selectedEmployee != null
                          ? Colors.orange
                          : Colors.grey,
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

  Widget _buildEmployeeSelectorCard() {
    if (_isLoadingEmployees) {
      return Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Column(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(height: 12),
                Text(
                  'Loading employees...',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_selectedEmployee != null) {
      return _buildSelectedEmployeeCard();
    }

    // No employee selected — show selector prompt
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: _openEmployeeSelector,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_search_rounded,
                  size: 28,
                  color: Colors.blue.shade700,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Who are you?',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap to select your name',
                      style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 20,
                color: Colors.grey[400],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedEmployeeCard() {
    final emp = _selectedEmployee!;
    final photoUrl = emp['photo_url'] as String?;
    final empId = emp['id'] as int;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [_getAvatarColor(empId).withOpacity(0.05), Colors.white],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Avatar
            Hero(
              tag: 'employee_avatar_$empId',
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _getAvatarColor(empId),
                  boxShadow: [
                    BoxShadow(
                      color: _getAvatarColor(empId).withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: photoUrl != null
                    ? ClipOval(
                        child: Image.network(
                          photoUrl,
                          fit: BoxFit.cover,
                          width: 60,
                          height: 60,
                          errorBuilder: (_, __, ___) => Center(
                            child: Text(
                              _getInitials(emp),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          _getInitials(emp),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${emp['first_name']} ${emp['last_name']}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    emp['position'] ?? '',
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.verified_rounded,
                        size: 14,
                        color: Colors.green.shade600,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Ready to verify',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green.shade600,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Change button
            TextButton.icon(
              onPressed: _openEmployeeSelector,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Change'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blue.shade700,
                backgroundColor: Colors.blue.shade50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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
