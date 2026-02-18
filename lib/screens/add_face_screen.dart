import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/face_service.dart';
import '../services/supabase_service.dart';
import '../widgets/camera_view.dart';

class AddFaceScreen extends StatefulWidget {
  final Map<String, dynamic> employee;
  const AddFaceScreen({super.key, required this.employee});

  @override
  State<AddFaceScreen> createState() => _AddFaceScreenState();
}

class _AddFaceScreenState extends State<AddFaceScreen> {
  CameraController? _cameraController;
  final FaceService _faceService = FaceService();
  final SupabaseService _supabaseService = SupabaseService();

  bool _isDetecting = false;
  String _statusMessage = "Align face to capture";
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    List<CameraDescription> cameras = [];
    try {
      cameras = await availableCameras();
    } catch (e) {
      _showError("Camera error: $e");
      return;
    }

    if (cameras.isEmpty) {
      _showError("No cameras found");
      return;
    }

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
    if (mounted) setState(() {});

    // Start detection mainly for UI feedback (optional, but good UX)
    _startFaceDetection();
  }

  void _startFaceDetection() {
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;

    _cameraController!.startImageStream((image) async {
      if (_isDetecting || _isProcessing) return;
      _isDetecting = true;

      try {
        // Just a lightweight check to guide user
        final result = await _faceService.processImage(
          image,
          _cameraController!.description.sensorOrientation,
        );

        if (mounted) {
          if (result['error'] == null) {
            // Face found
            // We don't update status too aggressively to avoid flickering custom messages
          }
        }
      } catch (e) {
        // ignore
      } finally {
        _isDetecting = false;
      }
    });
  }

  Future<void> _captureAndVerify() async {
    if (_cameraController == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = "Keep still...";
    });

    try {
      // 1. Capture Image
      await _cameraController!.stopImageStream(); // Pause stream
      final XFile photo = await _cameraController!.takePicture();

      setState(() => _statusMessage = "Analyzing face...");

      // 2. Generate Embedding
      final embedding = await _faceService.getFaceEmbeddingFromFile(photo.path);

      if (embedding == null) {
        _showError("Could not extract face features. Try again.");
        _resumeCamera();
        return;
      }

      // 3. Verify Identity against THIS employee's existing encodings
      // We need to parse the existing encodings from the employee map
      final existingFeatures = widget.employee['face_features'];
      if (existingFeatures == null) {
        // Technically this shouldn't happen for an existing employee with face data,
        // but if they have NO face data yet (e.g. imported), we might allow it?
        // Requirement says "check if identical to EXISTING face encoding".
        // If none exist, we can't verify. But maybe we allow adding the first one?
        // Let's assume they must have at least one.
        _showError("No existing face data to verify against.");
        _resumeCamera();
        return;
      }

      List<List<double>> existingVectors = [];
      try {
        final decoded = jsonDecode(existingFeatures);
        if (decoded is List) {
          if (decoded.isNotEmpty && decoded.first is List) {
            existingVectors = (decoded)
                .map((e) => List<double>.from(e))
                .toList();
          } else {
            // Single vector legacy format
            existingVectors = [List<double>.from(decoded)];
          }
        }
      } catch (e) {
        // legacy string format
        // try manual parse if needed, but the sync logic standardizes this now.
      }

      bool isMatch = false;
      double maxScore = 0.0;

      for (final vector in existingVectors) {
        final score = _faceService.compareFaces(embedding, vector);
        if (score > maxScore) maxScore = score;
      }

      // Threshold 0.65 for "somewhat identical" (slightly looser than 0.7 strict auth)
      if (maxScore >= 0.65) {
        isMatch = true;
      }

      if (!isMatch) {
        _showError(
          "Face does not match this employee! (Score: ${(maxScore * 100).toStringAsFixed(1)}%)",
        );
        File(photo.path).delete().ignore(); // Clean up
        _resumeCamera();
        return;
      }

      // 4. Verification Passed - Upload
      setState(() => _statusMessage = "Verified! Saving & Syncing...");

      await _supabaseService.saveFaceDescriptor(
        widget.employee['id'],
        embedding,
      );

      // Update local database to reflect new face immediately
      await _supabaseService.syncEmployees();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Face encoding added & synced!"),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate change
      }
    } catch (e) {
      _showError("Error: $e");
      _resumeCamera();
    }
  }

  void _resumeCamera() {
    if (mounted) {
      setState(() {
        _isProcessing = false;
        _statusMessage = "Align face to capture";
      });
      _startFaceDetection();
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Add Face: ${widget.employee['first_name']}")),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_cameraController != null &&
                    _cameraController!.value.isInitialized)
                  CameraView(controller: _cameraController!)
                else
                  const Center(child: CircularProgressIndicator()),

                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.black54,
                    width: double.infinity,
                    child: Text(
                      _statusMessage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _captureAndVerify,
                icon: const Icon(Icons.camera_enhance),
                label: const Text("CAPTURE & VERIFY"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  backgroundColor: Colors.blue,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
