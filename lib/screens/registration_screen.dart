import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/face_service.dart';
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

  bool _isDetecting = false;
  String _statusMessage = "Align face to register";
  bool _isLiveFaceDetected = false;
  List<double>? _capturedDescriptor;
  String? _capturedImagePath; // Path to the frozen capture image
  bool _shouldCapture = false;

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
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
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
            if (result['error'] == 'No face detected') {
              setState(() {
                _statusMessage = "No face detected";
                _isLiveFaceDetected = false;
              });
            }
          } else {
            final isLive = result['isLive'] as bool;

            setState(() {
              _isLiveFaceDetected = isLive;
              _statusMessage = isLive
                  ? "Face Detected - Ready to Capture"
                  : "Spoof Detected";
            });

            // Capture Logic: when button pressed and live face confirmed
            if (_shouldCapture && isLive) {
              _shouldCapture = false;

              setState(() {
                _statusMessage = "Capturing...";
              });

              // 1. Stop the image stream
              await _cameraController!.stopImageStream();

              // 2. Take a still photo (frozen preview + source for embedding)
              try {
                final XFile photo = await _cameraController!.takePicture();

                if (mounted) {
                  setState(() {
                    _capturedImagePath = photo.path;
                    _statusMessage = "Generating face data...";
                  });
                }

                // 3. Generate embedding from the saved JPEG file
                final embedding = await _faceService.getFaceEmbeddingFromFile(
                  photo.path,
                );

                if (embedding != null && mounted) {
                  setState(() {
                    _capturedDescriptor = embedding;
                    _statusMessage = "Face Captured Successfully!";
                  });
                } else if (mounted) {
                  // Embedding failed — show reason, clear image, restart
                  final reason = _faceService.isInterpreterReady
                      ? "No face found in photo"
                      : "Model not loaded: ${_faceService.interpreterErrorMessage}";
                  setState(() {
                    _capturedImagePath = null;
                    _statusMessage = "Capture failed: $reason";
                  });
                  _startFaceDetection();
                }
              } catch (e) {
                debugPrint("Capture error: $e");
                if (mounted) {
                  setState(() {
                    _statusMessage = "Capture error: $e";
                  });
                  _startFaceDetection();
                }
              }
              return; // Don't continue processing in this callback
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

  void _retakeFace() {
    // Clean up the old captured image file
    if (_capturedImagePath != null) {
      try {
        File(_capturedImagePath!).deleteSync();
      } catch (_) {}
    }

    setState(() {
      _capturedDescriptor = null;
      _capturedImagePath = null;
      _shouldCapture = false;
      _statusMessage = "Align face to register";
      _isLiveFaceDetected = false;
    });

    // Restart the face detection stream
    _startFaceDetection();
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
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        String errorMsg = e.toString();
        if (e is PostgrestException) {
          errorMsg = '${e.message} (${e.details ?? e.hint ?? e.code})';
        }
        debugPrint('Registration error: $e');
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
    // Clean up temp captured image
    if (_capturedImagePath != null) {
      try {
        File(_capturedImagePath!).deleteSync();
      } catch (_) {}
    }
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
                    onPressed: _isLiveFaceDetected
                        ? () => setState(() => _shouldCapture = true)
                        : null,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text("Capture Face"),
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

    // Show captured/frozen image after successful capture
    if (_capturedDescriptor != null && _capturedImagePath != null) {
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

    // Fallback: descriptor captured but no image (rare edge case)
    if (_capturedDescriptor != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 60),
            const SizedBox(height: 8),
            Text(_statusMessage),
          ],
        ),
      );
    }

    // Live camera preview
    return Stack(
      children: [
        CameraView(controller: _cameraController!),
        Center(
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(
                color: _isLiveFaceDetected ? Colors.green : Colors.red,
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
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}
