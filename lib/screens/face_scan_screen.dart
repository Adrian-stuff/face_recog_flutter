import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config/kiosk_config.generated.dart';
import '../services/device_reporting_service.dart';
import '../services/face_service.dart';
import '../services/local_database_service.dart';
import '../services/permissions_service.dart';
import '../services/scan_evidence_service.dart';
import '../services/sound_service.dart';
import '../services/supabase_service.dart';
import '../services/update_service.dart';
import '../widgets/real_time_clock.dart';
import '../widgets/roll_call_panel.dart';
import '../widgets/scan_target_bar.dart';
import '../widgets/status_chip.dart';
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
  final LocalDatabaseService _localDb = LocalDatabaseService();

  bool _isProcessing = false;
  String _statusMessage = "Loading...";
  bool _isConnected = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  SyncStatus? _syncStatus;
  Timer? _syncStatusTimer;
  Timer? _updateCheckTimer;
  List<KioskPermission> _missingPermissions = [];

  // Employee selection state
  List<Map<String, dynamic>> _employees = [];
  Map<String, dynamic>? _selectedEmployee;
  bool _isLoadingEmployees = true;

  // Today's punches from this device, keyed by employee id — joined against
  // [_employees] to build the roll call. See
  // LocalDatabaseService.getTodayPunchesByEmployee for the "this device
  // only" caveat that the panel's footnote passes on to the reader.
  Map<int, Map<String, String>> _todayPunches = const {};

  // Next-action state, resolved when an employee is selected so the card badge
  // and action buttons can show context before any scan.
  String? _nextAction; // 'time-in'|'time-out'|'break-out'|'break-in'|'overtime-in'|'overtime-out'|'done'
  // Punches that are *also* valid right now. Mid-shift there are genuinely
  // two — go on break, or go home — and _nextAction can only carry one.
  List<String> _alsoAllowed = const [];
  bool _isLoadingNextAction = false;
  // Whether _nextAction came from the server (which sees every kiosk and any
  // overtime still open from yesterday) or was estimated from this device's
  // own punch history. Only an authoritative answer narrows the kiosk to a
  // single button; an estimate keeps both punches reachable, because the
  // estimate is wrong in exactly the situations where an employee most needs
  // the other one — a reinstalled app, or a shift started on another kiosk.
  bool _nextActionIsAuthoritative = false;

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

    // Release/patch numbers for the version dialog. Read once — they only
    // change across a restart, which rebuilds this screen anyway.
    UpdateService.instance.loadVersionInfo();

    // A kiosk runs for weeks without anyone touching it, so a check that only
    // happened at launch would leave it sitting on stale code indefinitely —
    // which is exactly how this fleet ended up running builds nobody could
    // identify. Half-hourly is far below Shorebird's rate limits and keeps
    // "Up to date" an honest claim rather than a stale one.
    UpdateService.instance.checkAndUpdate();
    _updateCheckTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => UpdateService.instance.checkAndUpdate(),
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
      // Coming back from the background is the cheapest moment to notice a
      // patch published while the kiosk was idle.
      UpdateService.instance.checkAndUpdate();
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
    await _loadTodayPunches();
  }

  Future<void> _loadTodayPunches() async {
    try {
      final punches = await _localDb.getTodayPunchesByEmployee();
      if (mounted) setState(() => _todayPunches = punches);
    } catch (e) {
      // The roll call is a convenience, never a precondition for punching —
      // a failed read leaves the last good list on screen rather than
      // taking the scan screen down with it.
      debugPrint('Error loading today\'s punches: $e');
    }
  }

  void _selectEmployee(Map<String, dynamic> employee) {
    setState(() {
      _selectedEmployee = employee;
      _nextAction = null; // reset while loading
      _alsoAllowed = const [];
      _nextActionIsAuthoritative = false;
    });
    _loadNextAction(employee['id'] as int);
  }

  void _openEmployeeSelector() async {
    final selected = await SearchableEmployeeSelector.show(context, _employees);
    if (selected != null && mounted) {
      _selectEmployee(selected);
    }
  }

  Future<void> _loadNextAction(int employeeId) async {
    if (!mounted) return;
    setState(() => _isLoadingNextAction = true);
    final result = await _supabaseService.getEmployeeNextAction(employeeId);
    if (mounted) {
      setState(() {
        _nextAction = result.action;
        _alsoAllowed = result.alsoAllowed;
        _nextActionIsAuthoritative = result.authoritative;
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

    // Declared outside the try so the catch block below can still attach
    // them to a rejected-scan record — by the time recordAttendance() throws
    // a duplicate-punch error, the face was already matched, so this is the
    // same evidence a successful scan would have carried.
    String? thumbnail;
    dynamic similarity;

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
      thumbnail = await ScanEvidenceService.thumbnailFromFile(photoPath);

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
        // Two different failures reach this branch, and they were being
        // reported as the same one. If the device holds no face data for this
        // employee, nothing was compared — saying "did not match" blames the
        // person in front of the camera for a gap in the kiosk's own roster.
        // Offline the distinction is the whole story, because the online
        // fallback that would otherwise have found their face is unreachable.
        final hasFaceData = await _supabaseService.hasCachedFaceFor(employeeId);

        // The employee may well insist this was them. Keeping the capture
        // means the question can be settled by looking, rather than by
        // whether anyone believes the kiosk.
        await _supabaseService.recordFailedScan(
          outcome: hasFaceData ? 'no_match' : 'no_face_data',
          thumbnail: thumbnail,
          employeeId: employeeId,
          employeeName: '$firstName $lastName',
          livenessPassed: true,
          reason: hasFaceData
              ? 'Face did not match the selected employee'
              : 'This kiosk holds no face data for this employee, so nothing was compared. '
                  'Their face was enrolled after the last sync, or on another device.',
        );

        await _soundService.playError(
          message: hasFaceData
              ? "Face does not match $firstName $lastName"
              : "No face data on this device for $firstName $lastName",
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    // Telling someone their face did not match, when the
                    // kiosk never had their face, sends them to re-scan over
                    // and over on a problem only an admin can clear.
                    child: Text(
                      hasFaceData
                          ? "Face does not match the selected employee. Please try again or select the correct employee."
                          : "This kiosk has no face data for $firstName $lastName yet. Ask your administrator to sync this device.",
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
        // The no-match branch runs after an await, so the screen may already
        // be gone — a WiFi blip tears this route down mid-scan. Every other
        // setState in this method is guarded; this one was missed, and an
        // unguarded setState after dispose surfaces as "Null check operator
        // used on a null value" from State.setState, which is what the kiosk
        // reported against _recordAttendance.
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _statusMessage = "Ready";
          });
        }
        return;
      }

      // Face matched! Record attendance + improve dataset
      similarity = matchResult['similarity'];

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
            _alsoAllowed = const [];
            _nextActionIsAuthoritative = false;
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
      } else {
        // The face matched and passed liveness, but recordAttendance()
        // declined to write it (already timed in today, active overtime
        // session, etc.). That's exactly the kind of attempt Scan History
        // exists to prove happened — without this, it vanished the same way
        // no-match/liveness-failed scans used to before recordFailedScan()
        // was added for them.
        await _supabaseService.recordFailedScan(
          outcome: 'device_rejected',
          thumbnail: thumbnail,
          employeeId: employeeId,
          employeeName: '$firstName $lastName',
          matchConfidence: similarity is num ? similarity.toDouble() : null,
          livenessPassed: true,
          reason: displayMessage,
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
      // The punch that just landed (or was refused) is what the roll call
      // above is reporting on, so refresh it before the employee walks away
      // — seeing their own name move columns is the confirmation.
      _loadTodayPunches();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _syncStatusTimer?.cancel();
    _updateCheckTimer?.cancel();
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
                  // One message for both "wrong password" and "correct
                  // password, but this account doesn't administer this
                  // kiosk's company" — matching the server, which returns the
                  // same 403 either way. A login prompt sitting in a waiting
                  // room shouldn't report which companies an email belongs to.
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Invalid credentials, or this account cannot administer this kiosk.",
                      ),
                      backgroundColor: KioskColors.error,
                      duration: Duration(seconds: 5),
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
      // The bar carries identity and the two destinations, nothing else.
      // Everything that reports *state* moved to the strip below it: with the
      // connectivity pill, sync badge, permission badge and two icon buttons
      // all competing for the right edge, a company name of any real length
      // was squeezed to the point of truncation, and each badge had been
      // styled slightly differently from the last.
      appBar: AppBar(
        titleSpacing: 16,
        title: ValueListenableBuilder<String?>(
          valueListenable: _supabaseService.companyName,
          builder: (context, name, _) {
            // "Face Attendance" is dropped from the title — it's the only
            // thing this kiosk does, so it spent its characters saying
            // nothing and pushed the company name into an ellipsis.
            return Text(
              name ?? 'Face Attendance',
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: "Today's attendance",
            icon: const Icon(Icons.groups),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TodayAttendanceScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Admin',
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: _showAdminLoginDialog,
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: _buildStatusStrip(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_recentRejections.isNotEmpty) _buildRejectionBanner(),

            // The page itself no longer scrolls. On a kiosk everything here
            // is either always relevant (the clock, who is selected, the
            // punch buttons) or is a list that scrolls on its own, and a
            // scrolling page just meant the buttons could be somewhere off
            // screen when someone reached for them.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Date & Time
                  const Center(child: RealTimeClock()),
                  const SizedBox(height: 16),

                  // 2. Status Display
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: KioskColors.info.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: KioskColors.info.withValues(alpha: 0.3),
                      ),
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
                ],
              ),
            ),

            // 3. Roll call — who still owes a punch today, and the fastest
            // way to pick yourself. Takes whatever height is left.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: _isLoadingEmployees
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : RollCallPanel(
                        employees: _employees,
                        punches: _todayPunches,
                        selectedEmployeeId: _selectedEmployee?['id'] as int?,
                        // Null while a scan is in flight, which greys out
                        // tapping rather than letting a second employee be
                        // selected out from under the one being recorded.
                        onSelect: _isProcessing ? null : _selectEmployee,
                      ),
              ),
            ),

            // 4. Who is being scanned + the punch buttons, pinned together at
            // the bottom. The identity has to travel with the buttons: it is
            // the thing the button is about to act on, and a card left up in
            // the scroll body is off screen at the moment it matters most.
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                // Without this the punch buttons shrink to their label width
                // and sit marooned in the middle of the bar, which on a
                // kiosk is the one control that should be impossible to miss.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ScanTargetBar(
                    employee: _selectedEmployee,
                    nextAction: _nextAction,
                    isLoadingNextAction: _isLoadingNextAction,
                    onChange: _isProcessing ? null : _openEmployeeSelector,
                    onSelect: _isProcessing ? null : _openEmployeeSelector,
                  ),
                  const SizedBox(height: 12),
                  _buildNextActionButtons(),
                ],
              ),
            ),
          ],
        ),
      ),
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
  /// Narrowing to one button only happens on an authoritative answer — one
  /// the server gave. An offline kiosk, or one whose status lookup timed out,
  /// falls back to the local estimate and shows both punches, because acting
  /// on a wrong guess there would strand an employee with no way to clock
  /// out. So the kiosk stays fully usable offline; it just stops narrowing.
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
        // access_time rather than an hourglass, which would read better here
        // but is not in the shipped icon font. Flutter tree-shakes
        // MaterialIcons down to the glyphs a build actually references, and
        // Shorebird patches carry code only — never assets. Referencing a
        // glyph the installed release didn't bundle renders an empty box on
        // the kiosk. Any new icon has to wait for a full release.
        icon: Icons.access_time_rounded,
        onPressed: null,
      );
    }

    // Only the server sees every kiosk, and any overtime still open from
    // yesterday. Without its answer the kiosk keeps both punches reachable
    // rather than acting on a local guess — see _buildBothPunchButtons.
    if (!_nextActionIsAuthoritative) {
      return _buildBothPunchButtons();
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
        // Mid-shift the employee can go on break or go home, and both are
        // legitimate. TIME OUT keeps the full width because it is the one
        // that ends the day; START BREAK sits beside it rather than above,
        // so the muscle memory for timing out does not move.
        if (_alsoAllowed.contains('break-out')) {
          return Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildActionButton(
                  label: 'TIME OUT',
                  color: KioskColors.warning,
                  icon: Icons.logout,
                  onPressed: _isProcessing
                      ? null
                      : () => _recordAttendance('time-out'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _buildActionButton(
                  label: 'START BREAK',
                  color: const Color(0xFF6A4CB8),
                  // wb_sunny reads as midday. There is no coffee cup in the
                  // 84 glyphs release 1.2.0+67 bundles, and a patch carries
                  // no assets — an icon outside that set is an empty box on
                  // every kiosk while looking correct locally.
                  icon: Icons.wb_sunny,
                  onPressed: _isProcessing
                      ? null
                      : () => _recordAttendance('break-out'),
                ),
              ),
            ],
          );
        }
        return _buildActionButton(
          label: 'TIME OUT',
          color: KioskColors.warning,
          icon: Icons.logout,
          onPressed: _isProcessing ? null : () => _recordAttendance('time-out'),
        );

      case 'break-out':
        return _buildActionButton(
          label: 'START BREAK',
          color: const Color(0xFF6A4CB8),
          icon: Icons.wb_sunny,
          onPressed: _isProcessing
              ? null
              : () => _recordAttendance('break-out'),
        );

      case 'break-in':
        return _buildActionButton(
          label: 'BACK FROM BREAK',
          color: KioskColors.success,
          icon: Icons.login_rounded,
          onPressed: _isProcessing ? null : () => _recordAttendance('break-in'),
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
        return _buildBothPunchButtons();
    }
  }

  /// Both punches side by side, used whenever the kiosk isn't certain which
  /// one comes next.
  ///
  /// This is the offline shape. The local estimate can't see a shift started
  /// on another kiosk, a roster that arrived after a reinstall, or an overtime
  /// session still open from yesterday — all of which look like "hasn't timed
  /// in yet" here. Narrowing to one button on a guess that wrong would leave a
  /// real employee standing at a kiosk with no way to clock out, which is a
  /// far worse failure than showing one button too many.
  Widget _buildBothPunchButtons() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            label: 'TIME IN',
            color: KioskColors.success,
            icon: Icons.login,
            onPressed: _isProcessing ? null : () => _recordAttendance('time-in'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildActionButton(
            label: 'TIME OUT',
            color: KioskColors.warning,
            icon: Icons.logout,
            onPressed: _isProcessing ? null : () => _recordAttendance('time-out'),
          ),
        ),
      ],
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

  /// Badge showing unsynced/failed record counts, so an outage on this
  /// device isn't invisible until the server's 7-day sync window expires
  /// and records start silently disappearing. Red (failed) takes priority
  /// over amber (still pending, will keep retrying).
  /// The header's state row: connectivity, updates, sync backlog, permissions.
  ///
  /// Horizontally scrollable rather than wrapping or eliding. Which chips are
  /// present depends on runtime conditions, so the row's width isn't knowable
  /// at design time; scrolling means a narrow kiosk in portrait degrades to a
  /// swipe instead of a RenderFlex overflow.
  Widget _buildStatusStrip() {
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
        child: Row(
          children: [
            StatusChip(
              icon: _isConnected ? Icons.wifi : Icons.wifi_off,
              label: _isConnected ? 'Online' : 'Offline',
              color: _isConnected ? KioskColors.success : KioskColors.error,
            ),
            _buildUpdateChip(),
            if (_syncStatus?.hasIssues == true) _buildSyncStatusChip(),
            if (_missingPermissions.isNotEmpty) _buildPermissionAlertChip(),
          ],
        ),
      ),
    );
  }

  /// Update status, tappable for the exact release and patch it's running.
  Widget _buildUpdateChip() {
    return ValueListenableBuilder<AppUpdateState>(
      valueListenable: UpdateService.instance.state,
      builder: (context, state, _) {
        // A debug or profile build has no Shorebird updater behind it, so
        // there is no honest status to show — better an absent chip than one
        // permanently claiming "up to date".
        if (state == AppUpdateState.unavailable) return const SizedBox.shrink();

        final (label, color, icon, busy) = switch (state) {
          AppUpdateState.checking => (
              'Checking…', KioskColors.muted, Icons.sync_rounded, true,
            ),
          AppUpdateState.downloading => (
              'Updating…', KioskColors.info, Icons.cloud_sync, true,
            ),
          AppUpdateState.readyToRestart => (
              'Restart to update', KioskColors.warning, Icons.system_update, false,
            ),
          AppUpdateState.upToDate => (
              'Up to date', KioskColors.success, Icons.check_circle_outline_rounded, false,
            ),
          AppUpdateState.failed => (
              'Update failed', KioskColors.error, Icons.error_outline_rounded, false,
            ),
          _ => ('Checking…', KioskColors.muted, Icons.sync_rounded, true),
        };

        return StatusChip(
          icon: icon,
          label: label,
          color: color,
          busy: busy,
          onTap: _showUpdateDialog,
        );
      },
    );
  }

  Widget _buildSyncStatusChip() {
    final status = _syncStatus!;
    final hasFailed = status.failedCount > 0;
    return StatusChip(
      icon: hasFailed ? Icons.error_outline : Icons.cloud_upload_outlined,
      label: hasFailed
          ? '${status.failedCount} sync issue${status.failedCount == 1 ? '' : 's'}'
          : '${status.pendingCount} pending',
      color: hasFailed ? KioskColors.error : KioskColors.warning,
      onTap: () => _showSyncStatusDialog(status),
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

  Widget _buildPermissionAlertChip() {
    final hasCritical = _missingPermissions.any((p) => p.critical);
    return StatusChip(
      icon: Icons.no_accounts,
      label: _missingPermissions.length == 1
          ? '${_missingPermissions.first.label} off'
          : '${_missingPermissions.length} permissions off',
      color: hasCritical ? KioskColors.error : KioskColors.warning,
      onTap: _showPermissionDialog,
    );
  }

  /// Exactly what code this device is running, and how current it is.
  ///
  /// Worth a dialog rather than a tooltip: when a fleet misbehaves, the first
  /// question is always "which build is that kiosk actually on", and until now
  /// answering it meant cross-referencing the dashboard. A patch number is
  /// also not the same as a release version — Shorebird replaces Dart code
  /// underneath a fixed release, so both have to be shown to identify a build.
  Future<void> _showUpdateDialog() async {
    final service = UpdateService.instance;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('App version'),
        // Listens to all three, not just state: the version and patch are
        // read asynchronously and currentPatch changes again after a
        // download, so a dialog bound only to state would sit showing
        // "Unknown" or a stale patch number.
        content: ListenableBuilder(
          listenable: Listenable.merge([
            service.state,
            service.releaseVersion,
            service.currentPatch,
          ]),
          builder: (context, _) {
            final state = service.state.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VersionRow(
                  label: 'Release',
                  value: service.releaseVersion.value ?? 'Unknown',
                ),
                const SizedBox(height: 8),
                VersionRow(
                  label: 'Patch',
                  // No patch installed means running the release as built,
                  // which is a real state and not an error.
                  value: service.currentPatch.value?.toString() ?? 'None (base release)',
                ),
                const SizedBox(height: 8),
                VersionRow(label: 'Status', value: _updateStatusText(state)),
                if (state == AppUpdateState.readyToRestart) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Close and reopen the app to finish updating.',
                    style: TextStyle(
                      fontSize: 13,
                      color: KioskColors.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ValueListenableBuilder<AppUpdateState>(
            valueListenable: service.state,
            builder: (context, state, _) {
              final busy = state == AppUpdateState.checking ||
                  state == AppUpdateState.downloading;
              return TextButton.icon(
                onPressed: busy ? null : () => service.checkAndUpdate(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Check now'),
              );
            },
          ),
        ],
      ),
    );
  }

  String _updateStatusText(AppUpdateState state) => switch (state) {
        AppUpdateState.checking => 'Checking for updates…',
        AppUpdateState.downloading => 'Downloading update…',
        AppUpdateState.readyToRestart => 'Update ready — restart required',
        AppUpdateState.upToDate => 'Up to date',
        AppUpdateState.failed => 'Last update check failed',
        AppUpdateState.unavailable => 'Updates not available in this build',
        AppUpdateState.unknown => 'Not checked yet',
      };

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
