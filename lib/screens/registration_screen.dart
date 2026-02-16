import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/face_service.dart';
import '../services/sound_service.dart';
import '../services/supabase_service.dart';
import '../widgets/camera_view.dart';
import 'settings_screen.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _positionController = TextEditingController();
  final _emailController = TextEditingController();
  final _contactController = TextEditingController();
  final _addressController = TextEditingController();

  CameraController? _cameraController;
  final FaceService _faceService = FaceService();
  final SupabaseService _supabaseService = SupabaseService();
  final SoundService _soundService = SoundService();

  bool _isDetecting = false;
  String _statusMessage = "Align face to register";
  List<double>? _capturedDescriptor;
  String? _capturedImagePath; // Path to the frozen capture image

  // Blink Verification State
  bool _isVerifyingBlink = false;
  bool _eyesClosedDetected = false;
  bool _isFaceAligned = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    await _faceService.initialize();
    await _soundService.initialize();
    if (mounted) {
      setState(() {
        if (!_faceService.isInterpreterReady) {
          _statusMessage =
              "⚠ Model failed to load: ${_faceService.interpreterErrorMessage}";
        }
      });
      _startFaceDetection();
    }
  }

  void _startFaceDetection() {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _cameraController!.value.isStreamingImages) {
      return;
    }

    _cameraController!.startImageStream((image) async {
      if (_isDetecting) return;
      _isDetecting = true;

      try {
        final result = await _faceService.processImage(
          image,
          _cameraController!.description.sensorOrientation,
        );

        if (mounted) {
          if (result['error'] != null) {
            final error = result['error'];
            setState(() {
              _isFaceAligned = false;
              if (error == 'No face detected') {
                if (!_isVerifyingBlink) _statusMessage = "No face detected";
              } else if (error == 'Multiple faces detected') {
                _statusMessage = "Multiple faces detected - Only one allowed";
              }
            });
          } else {
            // Face Found
            if (!_isVerifyingBlink && _capturedDescriptor == null) {
              setState(() {
                _isFaceAligned = true;
                _statusMessage = "Face Detected - Ready to Capture";
              });
            } else if (_isVerifyingBlink) {
              // --- Blink Verification Logic ---
              final double leftEye = result['leftEyeOpen'] ?? 1.0;
              final double rightEye = result['rightEyeOpen'] ?? 1.0;

              // Thresholds (tunable)
              const double closeThreshold = 0.2;
              const double openThreshold = 0.8;

              if (leftEye < closeThreshold && rightEye < closeThreshold) {
                _eyesClosedDetected = true;
              }

              if (_eyesClosedDetected &&
                  (leftEye > openThreshold && rightEye > openThreshold)) {
                // Blink Completed!
                _finalizeCapture();
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error processing image: $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  Future<void> _initiateCapture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;

    setState(() {
      _statusMessage = "Capturing...";
      _isDetecting = true; // Block stream processing mainly
    });

    // 1. Pause Stream (implicitly handled by taking picture logic usually, but let's be safe)
    await _cameraController!.stopImageStream();

    // 2. Take Picture
    try {
      final XFile photo = await _cameraController!.takePicture();

      // 3. Save, but don't finalize yet
      _capturedImagePath = photo.path;

      if (mounted) {
        setState(() {
          _statusMessage = "Please BLINK to verify liveness";
          _isVerifyingBlink = true;
          _eyesClosedDetected = false;
          _isDetecting = false; // Reset lock
        });

        // 4. Resume Stream for Blink Check
        _startFaceDetection();
      }
    } catch (e) {
      debugPrint("Capture error: $e");
      _resetResetState("Capture failed: $e");
    }
  }

  Future<void> _finalizeCapture() async {
    // 5. Blink Verified - Stop Stream
    await _cameraController!.stopImageStream();

    setState(() {
      _isVerifyingBlink = false;
      _statusMessage = "Generating face data...";
    });

    try {
      // 6. Generate embedding from the PREVIOUSLY captured image
      if (_capturedImagePath != null) {
        final embedding = await _faceService.getFaceEmbeddingFromFile(
          _capturedImagePath!,
        );

        if (embedding != null && mounted) {
          setState(() {
            _capturedDescriptor = embedding;
            _statusMessage = "Face Captured Successfully!";
          });
        } else {
          _resetResetState("Failed to extract face features");
        }
      } else {
        _resetResetState("Image lost");
      }
    } catch (e) {
      _resetResetState("Error finalizing: $e");
    }
  }

  void _resetResetState(String msg) {
    // Clean file
    _cleanupTempFile();

    if (mounted) {
      setState(() {
        _capturedDescriptor = null;
        _capturedImagePath = null;
        _isVerifyingBlink = false;
        _eyesClosedDetected = false;
        _statusMessage = msg;
        _isDetecting = false;
      });
      // Restart
      _startFaceDetection();
    }
  }

  void _retakeFace() {
    _cleanupTempFile();

    setState(() {
      _capturedDescriptor = null;
      _capturedImagePath = null;
      _isVerifyingBlink = false;
      _eyesClosedDetected = false;
      _statusMessage = "Align face to register";
    });

    // Restart the face detection stream
    _startFaceDetection();
  }

  void _cleanupTempFile() {
    if (_capturedImagePath != null) {
      try {
        File(_capturedImagePath!).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate()) return;
    if (_capturedDescriptor == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please capture a face first.")),
      );
      return;
    }

    try {
      final employeeData = {
        'first_name': _firstNameController.text,
        'last_name': _lastNameController.text,
        'position': _positionController.text,
        'email': _emailController.text,
        'contact_number': _contactController.text,
        'address': _addressController.text,
      };

      if (_capturedImagePath != null) {
        // Atomic Flow: Insert -> Upload -> Rollback if fail
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Registering & Uploading...")),
          );
        }

        await _supabaseService.registerEmployeeWithPhoto(
          employeeData,
          _capturedDescriptor!,
          File(_capturedImagePath!),
        );
      } else {
        // Fallback (shouldn't happen given validation)
        await _supabaseService.registerEmployee(
          employeeData,
          _capturedDescriptor!,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Employee Registered Successfully!")),
        );
        await _soundService.playSuccess(message: "Registration Successful");
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        String errorMsg = e.toString();
        if (e is PostgrestException) {
          errorMsg = '${e.message} (${e.details ?? e.hint ?? e.code})';
        }
        debugPrint('Registration error: $e');

        await _soundService.playError(message: "Registration Failed");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Registration Error: $errorMsg"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _positionController.dispose();
    _emailController.dispose();
    _contactController.dispose();
    _addressController.dispose();
    _cleanupTempFile();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Register Employee"),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // Form Fields
                TextFormField(
                  controller: _firstNameController,
                  decoration: const InputDecoration(labelText: "First Name"),
                  validator: (v) => v?.isEmpty == true ? "Required" : null,
                ),
                TextFormField(
                  controller: _lastNameController,
                  decoration: const InputDecoration(labelText: "Last Name"),
                  validator: (v) => v?.isEmpty == true ? "Required" : null,
                ),
                TextFormField(
                  controller: _positionController,
                  decoration: const InputDecoration(labelText: "Position"),
                  validator: (v) => v?.isEmpty == true ? "Required" : null,
                ),
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: "Email"),
                ),
                TextFormField(
                  controller: _contactController,
                  decoration: const InputDecoration(
                    labelText: "Contact Number",
                  ),
                ),
                TextFormField(
                  controller: _addressController,
                  decoration: const InputDecoration(labelText: "Address"),
                ),
                const SizedBox(height: 20),

                // Camera / Captured Image Section
                SizedBox(
                  height: 300,
                  width: double.infinity,
                  child: _buildCameraSection(),
                ),
                const SizedBox(height: 10),

                if (_capturedDescriptor == null)
                  ElevatedButton.icon(
                    onPressed: (_isVerifyingBlink || !_isFaceAligned)
                        ? null // Disable button while verifying blink OR face not valid
                        : _initiateCapture,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(
                      _isVerifyingBlink ? "Blink to Verify..." : "Capture Face",
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isVerifyingBlink
                          ? Colors.grey
                          : Colors.blue,
                    ),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: _retakeFace,
                    icon: const Icon(Icons.refresh),
                    label: const Text("Retake Face"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                    ),
                  ),

                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitRegistration,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blue[900],
                    ),
                    child: const Text(
                      "REGISTER EMPLOYEE",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraSection() {
    // Camera not ready yet
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    // Show captured/frozen image ONLY after full success
    if (_capturedDescriptor != null &&
        _capturedImagePath != null &&
        !_isVerifyingBlink) {
      return Stack(
        children: [
          // Frozen captured face image
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.expand(
              child: Image.file(File(_capturedImagePath!), fit: BoxFit.cover),
            ),
          ),
          // Success overlay
          Center(
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.green, width: 3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Center(
                child: Icon(Icons.check_circle, color: Colors.green, size: 60),
              ),
            ),
          ),
          // Status bar
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(8),
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Live camera preview (Scanning OR Blink Verification)
    return Stack(
      children: [
        CameraView(controller: _cameraController!),
        Center(
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(
                color: _isVerifyingBlink
                    ? (_eyesClosedDetected ? Colors.yellow : Colors.blue)
                    : Colors.green,
                width: 3,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            color: Colors.black54,
            padding: const EdgeInsets.all(8),
            child: Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: _isVerifyingBlink
                    ? FontWeight.bold
                    : FontWeight.normal,
                fontSize: _isVerifyingBlink ? 18 : 14,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
