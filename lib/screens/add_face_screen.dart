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

    final result = await Navigator.push<Map<String, String>?>(
      context,
      MaterialPageRoute(builder: (_) => const MultiAngleCaptureScreen()),
    );

    if (result != null && result.isNotEmpty) {
      if (mounted) {
        setState(() {
          // Explicitly organize so 'center' is first (primary)
          List<String> sortedPaths = [];
          if (result.containsKey('center')) {
            sortedPaths.add(result['center']!);
          }
          for (var entry in result.entries) {
            if (entry.key != 'center') {
              sortedPaths.add(entry.value);
            }
          }
          _capturedImagePaths = sortedPaths;
          _statusMessage = "Photos captured! Ready to verify and save.";
        });
      }
    }
  }

  Future<void> _verifyAndSave({bool isReplacement = false}) async {
    if (_capturedImagePaths.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = "Validating all angles...";
    });

    try {
      // 1. Validate ALL photos first
      List<List<double>> validatedEmbeddings = [];
      final labels = ["Center", "Left", "Right", "Up", "Down"];

      for (int i = 0; i < _capturedImagePaths.length; i++) {
        final path = _capturedImagePaths[i];
        final label = i < labels.length ? labels[i] : "Image #${i + 1}";

        setState(() {
          _statusMessage = "Analyzing $label...";
        });

        final embedding = await _faceService.getFaceEmbeddingFromFile(path);

        if (embedding == null) {
          _showError("No face detected in $label photo. Please retake.");
          return; // Abort immediately
        }
        validatedEmbeddings.add(embedding);
      }

      // 2. Verify Identity against THIS employee's existing encodings (using Primary/Center)
      final primaryEmbedding = validatedEmbeddings.first;
      final existingFeatures = widget.employee['face_features'];

      if (existingFeatures == null) {
        debugPrint("No existing face data. Skipping verification.");
      } else {
        // Only verify if NOT replacing the dataset
        if (!isReplacement) {
          setState(() => _statusMessage = "Verifying identity...");

          double score = await _verifyMatch(primaryEmbedding, existingFeatures);

          // If score is -1, it means we have existingFeatures string but no valid vectors (empty list)
          // We should allow this as "first valid face"
          if (score == -1.0) {
            debugPrint(
              "Existing data invalid or empty. Treating as fresh start.",
            );
          } else if (score < 0.65) {
            _showError(
              "Identity Verification Failed! Score: ${(score * 100).toStringAsFixed(1)}%. Center face does not match existing records.",
            );
            return;
          }
        }
      }

      // 3. If Replacement, Delete Old Encodings
      if (isReplacement) {
        setState(() => _statusMessage = "Deleting old dataset...");
        await _supabaseService.deleteFaceEncodings(widget.employee['id']);
      }

      // 4. Save ALL validated embeddings
      setState(
        () => _statusMessage =
            "Verified! Saving ${validatedEmbeddings.length} photos...",
      );

      int savedCount = 0;
      for (final embedding in validatedEmbeddings) {
        await _supabaseService.saveFaceDescriptor(
          widget.employee['id'],
          embedding,
          isGolden: true,
        );
        savedCount++;
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
        _showError("Failed to save face records.");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<double> _verifyMatch(
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
      // If we can't parse, we can't verify.
      // Option: Return 1.0 (allow) or 0.0 (deny) or -1.0 (skip/empty)
      return -1.0;
    }

    if (existingVectors.isEmpty) {
      return -1.0; // No valid vectors found
    }

    // Strict check for "Add Face" to prevent poisoning the dataset
    double maxScore = 0.0;
    for (final vector in existingVectors) {
      final score = _faceService.compareFaces(newEmbedding, vector);
      if (score > maxScore) maxScore = score;
    }

    debugPrint("Verification Max Score: $maxScore");
    return maxScore;
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
                      onPressed: _isProcessing
                          ? null
                          : () => _showOptionsDialog(),
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
                          : const Text("SAVE OPTIONS"),
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

  Future<void> _showOptionsDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Choose Action"),
        content: const Text(
          "Do you want to APPEND these new scans to the existing dataset (Improve), or REPLACE the entire dataset for this employee?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              _confirmAndSave(replace: true);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: BorderSide(color: Colors.redAccent),
            ),
            child: const Text("REPLACE DATASET"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _confirmAndSave(replace: false);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: const Text("IMPROVE (APPEND)"),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndSave({required bool replace}) async {
    String message = replace
        ? "WARNING: This will DELETE all existing face data for this employee and replace it with these 5 new scans. This cannot be undone."
        : "This will add 5 new face templates to the existing dataset to improve recognition accuracy.";

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(replace ? "Confirm Replacement" : "Confirm Update"),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: replace ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
            ),
            child: Text(replace ? "Access Replace" : "Confirm & Save"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _verifyAndSave(isReplacement: replace);
    }
  }
}
