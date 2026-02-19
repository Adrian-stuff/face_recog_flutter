import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../services/face_service.dart';
import '../services/supabase_service.dart';
import 'multi_angle_capture_screen.dart';

class AddFaceScreen extends StatefulWidget {
  final Map<String, dynamic> employee;
  const AddFaceScreen({super.key, required this.employee});

  @override
  State<AddFaceScreen> createState() => _AddFaceScreenState();
}

class _AddFaceScreenState extends State<AddFaceScreen> {
  final FaceService _faceService = FaceService();
  final SupabaseService _supabaseService = SupabaseService();

  List<String> _capturedImagePaths = [];
  bool _isProcessing = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    await _faceService.initialize();
  }

  Future<void> _startMultiAngleCapture() async {
    // Reset previous captures if any
    setState(() {
      _capturedImagePaths = [];
      _statusMessage = null;
    });

    final result = await Navigator.push<List<String>?>(
      context,
      MaterialPageRoute(builder: (_) => const MultiAngleCaptureScreen()),
    );

    if (result != null && result.isNotEmpty) {
      if (mounted) {
        setState(() {
          _capturedImagePaths = result;
          _statusMessage = "Photos captured! Ready to verify and save.";
        });
      }
    }
  }

  Future<void> _verifyAndSave() async {
    if (_capturedImagePaths.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = "Verifying identity...";
    });

    try {
      // 1. Generate Embedding for the Primary (First) Photo
      // We assume the first photo is "Center" or at least a good reference.
      final primaryPath = _capturedImagePaths.first;
      final primaryEmbedding = await _faceService.getFaceEmbeddingFromFile(
        primaryPath,
      );

      if (primaryEmbedding == null) {
        _showError(
          "Could not extract face features from the primary photo. Please retake.",
        );
        return;
      }

      // 2. Verify Identity against THIS employee's existing encodings
      final existingFeatures = widget.employee['face_features'];
      if (existingFeatures == null) {
        // If employee has no existing faces, we might want to ALLOW this as their first "onboarding"
        // But for "Adding" to existing, we usually expect verification.
        // Let's allow it but warn, or strictly enforce?
        // Given "Improve Dataset", usually they already exist.
        // But if they were imported via CSV without photos, this is how they get their first one.
        // So we should ALLOW if empty, but VERIFY if exists.
        debugPrint("No existing face data. Skipping verification.");
      } else {
        bool isMatch = await _verifyMatch(primaryEmbedding, existingFeatures);
        if (!isMatch) {
          _showError(
            "Identity Verification Failed! Face does not match existing records.",
          );
          return;
        }
      }

      // 3. Save ALL photos as Golden Records
      setState(
        () => _statusMessage =
            "Verified! Processing ${_capturedImagePaths.length} photos...",
      );

      int savedCount = 0;
      for (int i = 0; i < _capturedImagePaths.length; i++) {
        final path = _capturedImagePaths[i];

        // We reuse the primary embedding for the first one to save time
        List<double>? embedding;
        if (i == 0) {
          embedding = primaryEmbedding;
        } else {
          embedding = await _faceService.getFaceEmbeddingFromFile(path);
        }

        if (embedding != null) {
          await _supabaseService.saveFaceDescriptor(
            widget.employee['id'],
            embedding,
            isGolden: true,
          );
          savedCount++;
        }
      }

      if (savedCount > 0) {
        // Force Sync
        await _supabaseService.syncEmployees();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Success! Added $savedCount golden face records."),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context, true); // Return success
        }
      } else {
        _showError("Failed to save any face records.");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<bool> _verifyMatch(
    List<double> newEmbedding,
    dynamic existingFeatures,
  ) async {
    List<List<double>> existingVectors = [];
    try {
      final decoded = jsonDecode(existingFeatures);
      if (decoded is List) {
        if (decoded.isNotEmpty && decoded.first is List) {
          existingVectors = (decoded).map((e) => List<double>.from(e)).toList();
        } else {
          // Single vector legacy format
          existingVectors = [List<double>.from(decoded)];
        }
      }
    } catch (e) {
      debugPrint("Error parsing existing features: $e");
      return false;
    }

    // Strict check for "Add Face" to prevent poisoning the dataset
    double maxScore = 0.0;
    for (final vector in existingVectors) {
      final score = _faceService.compareFaces(newEmbedding, vector);
      if (score > maxScore) maxScore = score;
    }

    debugPrint("Verification Max Score: $maxScore");

    // Threshold 0.65 for "somewhat identical"
    return maxScore >= 0.65;
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
      setState(() => _statusMessage = "Error: $msg");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Improve Dataset: ${widget.employee['first_name']}"),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),

            // Photos Preview
            if (_capturedImagePaths.isNotEmpty) ...[
              const Text(
                "Captured Angles:",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _capturedImagePaths.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (ctx, index) {
                    final labels = ["Center", "Left", "Right", "Up", "Down"];
                    final label = index < labels.length
                        ? labels[index]
                        : "#${index + 1}";

                    return Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_capturedImagePaths[index]),
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ] else
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.grey.shade300,
                    width: 1,
                    style: BorderStyle.solid,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.camera_front,
                      size: 40,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "No scans yet",
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 20),

            if (_statusMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _statusMessage!.startsWith("Error")
                        ? Colors.red.shade50
                        : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _statusMessage!.startsWith("Error")
                          ? Colors.red.shade200
                          : Colors.blue.shade200,
                    ),
                  ),
                  child: Text(
                    _statusMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _statusMessage!.startsWith("Error")
                          ? Colors.red.shade800
                          : Colors.blue.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

            if (_capturedImagePaths.isEmpty)
              ElevatedButton.icon(
                onPressed: _startMultiAngleCapture,
                icon: const Icon(Icons.face),
                label: const Text("START MULTI-ANGLE SCAN"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  elevation: 3,
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isProcessing ? null : _startMultiAngleCapture,
                      icon: const Icon(Icons.refresh),
                      label: const Text("RETAKE"),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing ? null : () => _confirmAndSave(),
                      icon: const Icon(Icons.save_alt),
                      label: _isProcessing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text("SAVE DATA"),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        elevation: 3,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndSave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Confirm Updates"),
        content: const Text(
          "This will upload 5 new face templates for this employee. Ensure the photos are clear and belong to the correct person.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text("Confirm & Save"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _verifyAndSave();
    }
  }
}
