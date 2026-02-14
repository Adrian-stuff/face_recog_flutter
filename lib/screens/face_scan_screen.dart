import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/face_service.dart';
import '../services/supabase_service.dart';
import '../widgets/camera_view.dart';
import '../widgets/face_overlay.dart';
import '../widgets/real_time_clock.dart';
import 'registration_screen.dart';

class FaceScanScreen extends StatefulWidget {
  const FaceScanScreen({super.key});

  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

class _FaceScanScreenState extends State<FaceScanScreen> {
  CameraController? _cameraController;
  bool _isDetecting = false;
  String _statusMessage = "Initializing...";
  List<CameraDescription> _cameras = [];

  final SupabaseService _supabaseService = SupabaseService();
  final FaceService _faceService = FaceService();

  bool _isLiveFaceDetected = false;
  bool _isProcessing = false; // Guards the capture+verify+record flow

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    // Wait briefly so NetworkGuard's location permission request finishes first
    // (PermissionHandler can only handle one request at a time)
    await Future.delayed(const Duration(milliseconds: 500));

    // Request camera permission (check status first to avoid unnecessary dialogs)
    var cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        if (mounted) {
          setState(() => _statusMessage = "Camera permission denied");
        }
        return;
      }
    }

    _cameras = await availableCameras();

    if (_cameras.isEmpty) {
      if (mounted) setState(() => _statusMessage = "No cameras found");
      return;
    }

    // Select front camera
    final frontCamera = _cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      await _faceService.initialize();

      if (mounted) {
        setState(() {
          _statusMessage = "Ready. Select Employee & Point camera.";
        });
        _startForFaceDetection();

        // Trigger background sync
        _supabaseService.syncEmployees();
        _supabaseService.syncLogs();
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = "Camera Error: $e");
    }
  }

  void _startForFaceDetection() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isDetecting) return;
      _isDetecting = true;

      try {
        final result = await _faceService.processImage(
          image,
          _cameraController!.description.sensorOrientation,
        );

        if (result['error'] != null) {
          if (mounted && !_isProcessing) {
            setState(() {
              if (result['error'] != 'No face detected') {
                _statusMessage = result['error'];
              } else {
                _statusMessage = "Align face to camera";
              }
              _isLiveFaceDetected = false;
            });
          }
        } else {
          final isLive = result['isLive'] as bool;
          final score = result['score'] as double?;

          if (mounted && !_isProcessing) {
            setState(() {
              _isLiveFaceDetected = isLive;
              if (isLive) {
                _statusMessage =
                    "Live face detected (${score?.toStringAsFixed(3)}) — Press TIME IN or TIME OUT";
              } else {
                _statusMessage =
                    "SPOOF DETECTED! (${score?.toStringAsFixed(3)})";
              }
            });
          }
        }
      } catch (e) {
        debugPrint("Error processing image: $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  /// Called when user presses TIME IN or TIME OUT.
  /// Stops stream → takes picture → generates embedding → verifies via RPC → records attendance.
  Future<void> _recordAttendance(String type) async {
    if (_isProcessing) return;
    if (!_isLiveFaceDetected) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("No live face detected")));
      }
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = "Verifying identity...";
    });

    try {
      // 1. Stop the image stream
      await _cameraController!.stopImageStream();

      // 2. Take a still photo
      final photo = await _cameraController!.takePicture();

      // 3. Generate embedding from the captured image
      final embedding = await _faceService.getFaceEmbeddingFromFile(photo.path);
      if (embedding == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Could not extract face from photo. Try again."),
              backgroundColor: Colors.red,
            ),
          );
        }
        _restartDetection();
        return;
      }

      // 4. Verify face against database (pgvector cosine similarity)
      final matchedEmployee = await _supabaseService.verifyFace(embedding);
      if (matchedEmployee == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Face not recognized. Please register first."),
              backgroundColor: Colors.red,
            ),
          );
        }
        _restartDetection();
        return;
      }

      // 5. Record attendance for the verified employee
      final employeeId = matchedEmployee['id'] as int;
      final firstName = matchedEmployee['first_name'] ?? '';
      final lastName = matchedEmployee['last_name'] ?? '';
      final similarity = matchedEmployee['similarity'];

      await _supabaseService.recordAttendance(employeeId, type);

      if (mounted) {
        final action = type == 'time-in' ? 'Time In' : 'Time Out';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$action recorded for $firstName $lastName '
              '(${(similarity * 100).toStringAsFixed(1)}% match)',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      _restartDetection();
    }
  }

  /// Restart the camera stream and reset state for the next person.
  void _restartDetection() {
    if (mounted) {
      setState(() {
        _isProcessing = false;
        _isLiveFaceDetected = false;
        _statusMessage = "Ready — Align face to camera";
      });
    }
    _startForFaceDetection();
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

              // Close dialog first
              Navigator.pop(dialogContext);

              final success = await _supabaseService.loginAdmin(
                email,
                password,
              );

              if (mounted) {
                if (success) {
                  // Stop camera before navigating to avoid resource conflict
                  if (_cameraController != null) {
                    await _cameraController!.stopImageStream();
                    await _cameraController!.dispose();
                    setState(() {
                      _cameraController = null;
                      _isDetecting = false;
                      _statusMessage = "Paused for Registration";
                    });
                  }

                  if (!mounted) return;

                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RegistrationScreen(),
                    ),
                  );

                  // Re-initialize camera when returning from RegistrationScreen
                  if (mounted) {
                    _initializeCamera();
                  }
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
  void dispose() {
    _cameraController?.dispose();
    _faceService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Face Attendance"),
        actions: [
          IconButton(
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: _showAdminLoginDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            CameraView(controller: _cameraController!)
          else
            Center(child: Text(_statusMessage)),

          FaceOverlay(
            isLive: _isLiveFaceDetected,
            statusMessage: _statusMessage,
            canRegister: _isLiveFaceDetected && !_isProcessing,
            onTimeIn: () => _recordAttendance('time-in'),
            onTimeOut: () => _recordAttendance('time-out'),
          ),

          // Clock Overlay
          const Positioned(
            top: 40,
            left: 0,
            right: 0,
            child: Center(child: RealTimeClock()),
          ),
        ],
      ),
    );
  }
}
