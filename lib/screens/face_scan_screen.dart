import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:table_calendar/table_calendar.dart';
import '../config/kiosk_config.generated.dart';
import '../services/device_reporting_service.dart';
import '../services/face_service.dart';
import '../services/permissions_service.dart';
import '../services/scan_evidence_service.dart';
import '../services/sound_service.dart';
import '../services/supabase_service.dart';
import '../widgets/real_time_clock.dart';
import '../widgets/weather_widget.dart';
import '../widgets/searchable_employee_selector.dart';
import '../widgets/punch_confirmation_dialog.dart';
import 'liveness_check_screen.dart';
import 'admin_dashboard_screen.dart';
import 'today_attendance_screen.dart';

class FaceScanScreen extends StatefulWidget {
  const FaceScanScreen({super.key});

  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

class _FaceScanScreenState extends State<FaceScanScreen>
    with WidgetsBindingObserver {
  final SupabaseService _supabaseService = SupabaseService();
  final FaceService _faceService = FaceService();
  final SoundService _soundService = SoundService();
  final PermissionsService _permissionsService = PermissionsService();

  bool _isProcessing = false;
  String _statusMessage = "Loading...";
  bool _isConnected = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  SyncStatus? _syncStatus;
  Timer? _syncStatusTimer;
  List<KioskPermission> _missingPermissions = [];

  // Calendar state
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // Employee selection state
  List<Map<String, dynamic>> _employees = [];
  Map<String, dynamic>? _selectedEmployee;
  bool _isLoadingEmployees = true;

  // Next-action state — computed from local DB when an employee is selected,
  // so the card badge and action buttons can show context before any scan.
  String? _nextAction; // 'time-in'|'time-out'|'overtime-in'|'overtime-out'|'done'
  bool _isLoadingNextAction = false;

  // Rejection notification state
  DateTime _lastRejectionCheckTime = DateTime.now().subtract(const Duration(minutes: 15));
  List<Map<String, dynamic>> _recentRejections = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initConnectivity();
    _initialize();
    _refreshSyncStatus();
    // Outages can persist for a while on a device nobody is watching —
    // poll periodically so pending/failed counts don't just reflect
    // whatever happened to be true when the screen first loaded.
    _syncStatusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshSyncStatus(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A revoked permission doesn't tell the app directly — Settings is the
    // only place that changes it, and Android doesn't notify a backgrounded
    // app the moment it happens. Resume is the one reliable point to notice:
    // it's exactly when someone would be coming back from granting (or
    // revoking) something there.
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    final missing = await _permissionsService.checkMissing();
    if (mounted) setState(() => _missingPermissions = missing);
  }

  Future<void> _refreshSyncStatus() async {
    final status = await _supabaseService.getSyncStatus();
    final rejections = await _supabaseService.getRecentRejections(_lastRejectionCheckTime);
    if (mounted) {
      setState(() {
        _syncStatus = status;
        if (rejections.isNotEmpty) {
          _recentRejections = [...rejections, ..._recentRejections];
          _lastRejectionCheckTime = DateTime.now();
        }
      });
    }
  }

  void _initConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      final justReconnected = isConnected && !_isConnected;
      if (mounted) setState(() => _isConnected = isConnected);

      // The actual reconnect-triggered sync lives in
      // SupabaseService.startBackgroundSync (service-level, so it fires
      // regardless of which screen is active). Duplicating that call here
      // would race it — whichever listener loses the race would see the
      // other's already-applied change as a server-side conflict and
      // wrongly log it as a failed sync. Just refresh the badge shortly
      // after so it reflects the sync that's already happening.
      if (justReconnected) {
        Future.delayed(const Duration(seconds: 3), _refreshSyncStatus);
      }
    });
  }

  Future<void> _initialize() async {
    // Request permissions upfront
    await [Permission.camera, Permission.location].request();
    await _checkPermissions();

    // Initialize FaceService (fast - returns after starting model load in background)
    try {
      await _faceService.initialize();
      await _soundService.initialize();

      // Set status based on model loading state
      if (mounted) {
        if (_faceService.isModelLoading) {
          setState(() => _statusMessage = "Loading face recognition model...");

          // Wait for model in background while showing status
          _faceService
              .waitForModelReady(timeout: const Duration(seconds: 45))
              .then((_) {
                if (mounted) {
                  setState(() => _statusMessage = "Ready");
                }
              })
              .catchError((e) {
                if (mounted) {
                  setState(
                    () =>
                        _statusMessage = "Model loading timeout. Offline mode.",
                  );
                  debugPrint('Model load timeout: $e');
                }
              });
        } else {
          setState(() => _statusMessage = "Ready");
        }
      }
    } catch (e) {
      debugPrint("FaceService init error: $e");
      if (mounted) setState(() => _statusMessage = "Service Error");
    }

    // Trigger background sync
    _supabaseService.startBackgroundSync();

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
      setState(() {
        _selectedEmployee = selected;
        _nextAction = null; // reset while loading
      });
      _loadNextAction(selected['id'] as int);
    }
  }

  Future<void> _loadNextAction(int employeeId) async {
    if (!mounted) return;
    setState(() => _isLoadingNextAction = true);
    final action = await _supabaseService.getEmployeeNextAction(employeeId);
    if (mounted) {
      setState(() {
        _nextAction = action;
        _isLoadingNextAction = false;
      });
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
          backgroundColor: KioskColors.warning,
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

    setState(() => _isProcessing = true);

    // If the next action would be overtime-in, show a confirmation dialog
    // before launching the liveness check — prevents an employee who forgot
    // they already timed out from accidentally starting overtime.
    if (_nextAction == 'overtime-in' && type == 'time-in') {
      final confirmed = await _showOvertimeConfirmation();
      if (!confirmed || !mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
        return;
      }
    }

    setState(() => _statusMessage = "Opening liveness check...");

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
            backgroundColor: KioskColors.warning,
          ),
        );
        setState(() {
          _isProcessing = false;
          _statusMessage = "Ready";
        });
        return;
      }

      setState(() => _statusMessage = "Verifying identity...");

      // Built once and reused across every outcome below, so a scan that
      // fails still carries a picture of who was standing there.
      final thumbnail = await ScanEvidenceService.thumbnailFromFile(photoPath);

      // Generate embedding from photo.
      final embedding = await _faceService.getFaceEmbeddingFromFile(photoPath);
      if (embedding == null) {
        await _supabaseService.recordFailedScan(
          outcome: 'liveness_failed',
          thumbnail: thumbnail,
          employeeId: employeeId,
          employeeName: '$firstName $lastName',
          livenessPassed: true,
          reason: 'No face could be extracted from the liveness capture',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Could not extract face. Try again."),
              backgroundColor: KioskColors.error,
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
        // The employee may well insist this was them. Keeping the capture
        // means the question can be settled by looking, rather than by
        // whether anyone believes the kiosk.
        await _supabaseService.recordFailedScan(
          outcome: 'no_match',
          thumbnail: thumbnail,
          employeeId: employeeId,
          employeeName: '$firstName $lastName',
          livenessPassed: true,
          reason: 'Face did not match the selected employee',
        );

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
              backgroundColor: KioskColors.error,
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

      // Improve Dataset (Fire & Forget). saveFaceDescriptor already falls
      // back to the offline queue internally when there's no connection —
      // gating this call on _isConnected would just skip queuing it and
      // lose the improvement entirely, rather than syncing it once back
      // online.
      _supabaseService
          .saveFaceDescriptor(employeeId, embedding)
          .then((_) {
            debugPrint("Dataset improved for employee $employeeId");
          })
          .catchError((e) {
            debugPrint("Failed to improve dataset (non-fatal): $e");
          });

      // Record Attendance — returns the effective type actually stored
      // (may differ from [type] if overtime promotion occurred) plus the
      // clientEventId this punch was saved under, so the confirmation
      // dialog below can poll whether it actually reached the server.
      final (:effectiveType, :clientEventId) = await _supabaseService
          .recordAttendance(
            employeeId,
            type,
            employeeName: '$firstName $lastName',
            scanThumbnail: thumbnail,
            matchConfidence: similarity is num ? similarity.toDouble() : null,
            livenessPassed: true,
          );
      // Captured now, not inside the dialog: the radio state at the moment
      // of recording is what determines whether polling for a server
      // outcome is even worth attempting.
      final recordedOffline = !await _supabaseService.isOnline;

      // Play Success Sound — use the real effectiveType so TTS says the
      // correct action (e.g. "Overtime In recorded" not "Time In recorded").
      final ttsMessage = switch (effectiveType) {
        'overtime-in' => 'Overtime In recorded for $firstName $lastName',
        'overtime-out' => 'Overtime Out recorded for $firstName $lastName',
        'time-in' => 'Time In recorded for $firstName $lastName',
        _ => 'Time Out recorded for $firstName $lastName',
      };
      await _soundService.playSuccess(message: ttsMessage);

      if (mounted) {
        final now = DateTime.now();
        final timeString =
            "${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}";

        // Resolve display labels from the effective type
        final (dialogTitle, dialogIcon, dialogColor) = switch (effectiveType) {
          'overtime-in' => (
              'Overtime Started!',
              Icons.more_time_rounded,
              const Color(0xFF00897B), // teal
            ),
          'overtime-out' => (
              'Overtime Ended!',
              Icons.timelapse_rounded,
              const Color(0xFFE65100), // deep-orange
            ),
          'time-in' => (
              'Time In Recorded!',
              Icons.check_circle_rounded,
              KioskColors.success,
            ),
          _ => (
              'Time Out Recorded!',
              Icons.check_circle_rounded,
              KioskColors.success,
            ),
        };

        // Extra subtitle for overtime actions
        final overtimeSubtitle = switch (effectiveType) {
          'overtime-in' => 'Overtime session has started.',
          'overtime-out' => 'Overtime session has ended.',
          _ => null,
        };

        // Show success dialog — reports the real sync outcome (confirmed by
        // server / still offline / still syncing) rather than assuming the
        // local save means it's done.
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => PunchConfirmationDialog(
            title: dialogTitle,
            icon: dialogIcon,
            color: dialogColor,
            employeeName: '$firstName $lastName',
            timeString: timeString,
            similarity: similarity,
            overtimeSubtitle: overtimeSubtitle,
            recordedOffline: recordedOffline,
            clientEventId: clientEventId,
            checkPunchSyncState: _supabaseService.getPunchSyncState,
          ),
        );

        // Clear selection after successful recording
        if (mounted) {
          setState(() {
            _selectedEmployee = null;
            _nextAction = null;
          });
        }
      }
    } catch (e, stack) {
      // A plain Exception("...") here is one of this method's own
      // deliberate throws (e.g. "Attendance already recorded today") —
      // written to be read by whoever's standing at the kiosk, so it's
      // shown as-is. Anything else (DatabaseException, a network failure
      // that slipped past its own handling, etc.) was never meant to be
      // operator-facing — showing it raw just puts a wall of SQL in front
      // of an employee trying to time in. Those get a generic message
      // locally, while the real detail goes to the dashboard instead,
      // where it's actually actionable.
      //
      // Exception("message").toString() always renders as "Exception:
      // message" (verified against Dart's actual _Exception implementation
      // — its runtimeType is a private class, so it can't be checked
      // directly). DatabaseException and everything else render under
      // their own type name, e.g. "DatabaseException(...)", so this
      // reliably tells the two apart without enumerating every possible
      // "unexpected" exception type.
      final rawMessage = e.toString();
      final isKnownBusinessError = rawMessage.startsWith('Exception: ');
      final displayMessage = isKnownBusinessError
          ? rawMessage.replaceFirst('Exception: ', '')
          : "Something went wrong recording attendance. Please try again.";

      if (!isKnownBusinessError) {
        DeviceReportingService.instance.reportError(
          'Failed to record attendance: $e',
          context: 'face_scan_screen._recordAttendance type=$type\n$stack',
        );
      }

      if (mounted) {
        await _soundService.playError(message: "Error: $displayMessage");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(displayMessage),
            backgroundColor: KioskColors.error,
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
      _refreshSyncStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _syncStatusTimer?.cancel();
    super.dispose();
  }

  /// Shown before the liveness check when a 'time-in' tap would be promoted
  /// to 'overtime-in'. Returns true if the employee confirms, false to abort.
  Future<bool> _showOvertimeConfirmation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF00897B).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.more_time_rounded,
                size: 44,
                color: Color(0xFF00897B),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Starting Overtime',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              "You've already completed your regular shift today. "
              'Tapping in now will start an overtime session.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 4),
            Text(
              'Proceed with overtime?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: KioskColors.muted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: KioskColors.muted,
                    side: BorderSide(color: KioskColors.hairline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00897B),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: const Text(
                    'Start Overtime',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return confirmed == true;
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
                      backgroundColor: KioskColors.error,
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
        title: ValueListenableBuilder<String?>(
          valueListenable: _supabaseService.companyName,
          builder: (context, name, _) {
            return Text(name != null ? '$name — Face Attendance' : "Face Attendance");
          },
        ),
        centerTitle: true,
        actions: [
          // Internet Status Indicator
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _isConnected
                  ? KioskColors.success.withValues(alpha: 0.1)
                  : KioskColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isConnected ? KioskColors.success : KioskColors.error,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isConnected ? Icons.wifi : Icons.wifi_off,
                  color: _isConnected ? KioskColors.success : KioskColors.error,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  _isConnected ? "Online" : "Offline",
                  style: TextStyle(
                    color: _isConnected ? KioskColors.success : KioskColors.error,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (_syncStatus?.hasIssues == true) _buildSyncStatusBadge(),
          if (_missingPermissions.isNotEmpty) _buildPermissionAlertBadge(),
          IconButton(
            tooltip: "Today's attendance",
            icon: const Icon(Icons.groups),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TodayAttendanceScreen()),
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
            if (_recentRejections.isNotEmpty) _buildRejectionBanner(),
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
                        color: KioskColors.info.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: KioskColors.info.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: KioskColors.info,
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
              child: _buildNextActionButtons(),
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
                  style: TextStyle(color: KioskColors.muted),
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
                  color: KioskColors.info.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_search_rounded,
                  size: 28,
                  color: KioskColors.info,
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
                      style: TextStyle(fontSize: 14, color: KioskColors.muted),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 20,
                color: KioskColors.muted,
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
                    style: TextStyle(fontSize: 14, color: KioskColors.muted),
                  ),
                  const SizedBox(height: 4),
                  _buildShiftStateBadge(),
                ],
              ),
            ),

            // Change button
            TextButton.icon(
              onPressed: _openEmployeeSelector,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Change'),
              style: TextButton.styleFrom(
                foregroundColor: KioskColors.info,
                backgroundColor: KioskColors.info.withValues(alpha: 0.1),
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

  /// Inline status row for the selected-employee card. Shows the employee's
  /// current shift state so they know what pressing a button will do.
  Widget _buildShiftStateBadge() {
    if (_isLoadingNextAction) {
      return Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: KioskColors.muted,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Checking status…',
            style: TextStyle(fontSize: 12, color: KioskColors.muted),
          ),
        ],
      );
    }

    final (icon, label, color, highlight) = switch (_nextAction) {
      'time-in' => (
          Icons.login_rounded,
          'Ready to Time In',
          KioskColors.success,
          false,
        ),
      'time-out' => (
          Icons.access_time_rounded,
          'Active Shift — Tap to Time Out',
          KioskColors.warning,
          false,
        ),
      'overtime-in' => (
          Icons.more_time_rounded,
          'Regular Shift Done — Overtime Available',
          const Color(0xFF00897B),
          true, // draw a bordered pill to make it stand out
        ),
      'overtime-out' => (
          Icons.timelapse_rounded,
          'Overtime Active — Tap to Clock Out',
          const Color(0xFFE65100),
          false,
        ),
      'done' => (
          Icons.check_circle_outline_rounded,
          'Shift Complete',
          KioskColors.muted,
          false,
        ),
      _ => (
          Icons.verified_rounded,
          'Ready to verify',
          KioskColors.success,
          false,
        ),
    };

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );

    if (!highlight) return row;

    // For overtime-available, wrap in a pill so it really pops
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: row,
    );
  }

  /// The punch controls, showing only the action the employee can actually
  /// take next.
  ///
  /// Previously TIME IN and TIME OUT were both always live, and tapping the
  /// wrong one cost a full liveness check and face match before
  /// recordAttendance() rejected it ("You have already timed in today").
  /// Worse, once a regular shift was complete the TIME IN button quietly
  /// became an overtime-in — the single most consequential punch on the
  /// kiosk — with nothing but a relabel to say so. Driving the controls off
  /// [_nextAction] means the sequence time-in → time-out → overtime-in →
  /// overtime-out is the only one reachable by tapping.
  ///
  /// While the next action is still loading, or if that lookup failed
  /// (_nextAction == null), both punches stay available: guessing wrong
  /// there would strand an employee who genuinely needs to clock out.
  Widget _buildNextActionButtons() {
    if (_selectedEmployee == null) {
      return _buildActionButton(
        label: 'SELECT AN EMPLOYEE',
        color: KioskColors.muted,
        icon: Icons.person_search_rounded,
        onPressed: null,
      );
    }

    if (_isLoadingNextAction) {
      return _buildActionButton(
        label: 'CHECKING STATUS…',
        color: KioskColors.muted,
        icon: Icons.hourglass_top_rounded,
        onPressed: null,
      );
    }

    switch (_nextAction) {
      case 'time-in':
        return _buildActionButton(
          label: 'TIME IN',
          color: KioskColors.success,
          icon: Icons.login,
          onPressed: _isProcessing ? null : () => _recordAttendance('time-in'),
        );

      case 'time-out':
        return _buildActionButton(
          label: 'TIME OUT',
          color: KioskColors.warning,
          icon: Icons.logout,
          onPressed: _isProcessing ? null : () => _recordAttendance('time-out'),
        );

      case 'overtime-in':
        return _buildActionButton(
          label: 'OVERTIME IN',
          color: const Color(0xFF00897B), // teal
          icon: Icons.more_time_rounded,
          onPressed: _isProcessing ? null : () => _recordAttendance('time-in'),
        );

      case 'overtime-out':
        return _buildActionButton(
          label: 'OVERTIME OUT',
          color: const Color(0xFFE65100), // deep-orange
          icon: Icons.timelapse_rounded,
          onPressed: _isProcessing ? null : () => _recordAttendance('time-out'),
        );

      case 'done':
        return _buildActionButton(
          label: 'ALL DONE FOR TODAY',
          color: KioskColors.muted,
          icon: Icons.check_circle_outline_rounded,
          onPressed: null,
        );

      default:
        // Status unknown — fall back to offering both rather than locking
        // the employee out of the kiosk entirely.
        return Row(
          children: [
            Expanded(
              child: _buildActionButton(
                label: 'TIME IN',
                color: KioskColors.success,
                icon: Icons.login,
                onPressed:
                    _isProcessing ? null : () => _recordAttendance('time-in'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildActionButton(
                label: 'TIME OUT',
                color: KioskColors.warning,
                icon: Icons.logout,
                onPressed:
                    _isProcessing ? null : () => _recordAttendance('time-out'),
              ),
            ),
          ],
        );
    }
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

  /// Badge showing unsynced/failed record counts, so an outage on this
  /// device isn't invisible until the server's 7-day sync window expires
  /// and records start silently disappearing. Red (failed) takes priority
  /// over amber (still pending, will keep retrying).
  Widget _buildSyncStatusBadge() {
    final status = _syncStatus!;
    final hasFailed = status.failedCount > 0;
    final color = hasFailed ? KioskColors.error : KioskColors.warning;
    final label = hasFailed
        ? '${status.failedCount} sync issue${status.failedCount == 1 ? '' : 's'}'
        : '${status.pendingCount} pending';

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showSyncStatusDialog(status),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color, width: 1),
          ),
          child: Row(
            children: [
              Icon(
                hasFailed ? Icons.error_outline : Icons.cloud_upload_outlined,
                color: color,
                size: 16,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSyncStatusDialog(SyncStatus initialStatus) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          var status = initialStatus;

          Future<void> clearOne({int? logId, int? encodingId}) async {
            await _supabaseService.clearSyncIssue(
              logId: logId,
              encodingId: encodingId,
            );
            final refreshed = await _supabaseService.getSyncStatus();
            setDialogState(() => status = refreshed);
            _refreshSyncStatus();
          }

          Future<void> clearAll() async {
            await _supabaseService.clearAllSyncIssues();
            final refreshed = await _supabaseService.getSyncStatus();
            setDialogState(() => status = refreshed);
            _refreshSyncStatus();
          }

          return AlertDialog(
            title: const Text('Sync Status'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (status.pendingCount > 0)
                      Text(
                        '${status.pendingCount} record(s) waiting to sync — '
                        'will retry automatically once online.',
                      ),
                    if (status.failedCount > 0) ...[
                      if (status.pendingCount > 0) const SizedBox(height: 12),
                      const Text(
                        'These could not be synced and were not recorded on '
                        'the server. If this is a known duplicate (e.g. a '
                        'double check-in), you can clear it:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      for (final log in status.failedLogs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '• Attendance (employee ${log['employee_id']}, '
                                  '${log['type']}, ${log['timestamp']}): '
                                  '${log['sync_error']}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                tooltip: 'Clear this issue',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    clearOne(logId: log['id'] as int),
                              ),
                            ],
                          ),
                        ),
                      for (final enc in status.failedEncodings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '• Face data (employee ${enc['employee_id']}): '
                                  '${enc['sync_error']}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                tooltip: 'Clear this issue',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    clearOne(encodingId: enc['id'] as int),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              if (status.failedCount > 0)
                TextButton(
                  onPressed: clearAll,
                  child: const Text('Clear all issues'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRejectionBanner() {
    if (_recentRejections.isEmpty) return const SizedBox.shrink();

    final rejection = _recentRejections.first;
    final name = rejection['employee_name'] ?? 'Employee';
    final type = rejection['attendance_type'] ?? 'attendance';
    final reason = rejection['rejection_reason'] ?? 'Rejected by server';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KioskColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KioskColors.error),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: KioskColors.error, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Attendance Rejected ($name — $type)',
                  style: TextStyle(
                    color: KioskColors.error,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reason,
                  style: TextStyle(
                    color: KioskColors.baseContent,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () {
              setState(() {
                _recentRejections.removeAt(0);
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionAlertBadge() {
    final hasCritical = _missingPermissions.any((p) => p.critical);
    final color = hasCritical ? KioskColors.error : KioskColors.warning;
    final label = _missingPermissions.length == 1
        ? '${_missingPermissions.first.label} off'
        : '${_missingPermissions.length} permissions off';

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _showPermissionDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color, width: 1),
          ),
          child: Row(
            children: [
              Icon(Icons.no_accounts, color: color, size: 16),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPermissionDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> recheck() async {
            final missing = await _permissionsService.checkMissing();
            setDialogState(() => _missingPermissions = missing);
            if (mounted) setState(() => _missingPermissions = missing);
          }

          return AlertDialog(
            title: const Text('Permissions needed'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'This device revoked (or never granted) permissions '
                      'this kiosk needs. Grant them in Settings, then come '
                      'back — this app checks again automatically.',
                    ),
                    const SizedBox(height: 12),
                    for (final p in _missingPermissions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              p.critical ? Icons.error : Icons.warning_amber,
                              color: p.critical
                                  ? KioskColors.error
                                  : KioskColors.warning,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.label,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    p.consequence,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: recheck,
                child: const Text('Check again'),
              ),
              FilledButton(
                onPressed: () async {
                  await openAppSettings();
                  // The OS Settings app takes over the foreground; recheck
                  // happens automatically on resume (didChangeAppLifecycleState)
                  // once the user comes back, so nothing extra is needed here.
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Open Settings'),
              ),
            ],
          );
        },
      ),
    );
  }
}
