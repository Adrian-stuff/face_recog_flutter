import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/face_service.dart';
import '../services/sound_service.dart';
import '../services/supabase_service.dart';
import 'multi_angle_capture_screen.dart';
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

  final SupabaseService _supabaseService = SupabaseService();
  final SoundService _soundService = SoundService();
  final FaceService _faceService = FaceService();

  List<String> _capturedImagePaths = [];
  bool _isRegistering = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    await _soundService.initialize();
    await _faceService.initialize();
  }

  Future<void> _startMultiAngleCapture() async {
    final result = await Navigator.push<List<String>?>(
      context,
      MaterialPageRoute(builder: (_) => const MultiAngleCaptureScreen()),
    );

    if (result != null && result.isNotEmpty) {
      if (mounted) {
        setState(() {
          _capturedImagePaths = result;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Face scan completed successfully!"),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  void _retakeFace() {
    // Delete old temp files? Ideally yes, but OS cleans cache.
    // We can just clear the list.
    setState(() {
      _capturedImagePaths = [];
    });
    _startMultiAngleCapture();
  }

  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate()) return;
    if (_capturedImagePaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please complete the face scan first.")),
      );
      return;
    }

    setState(() => _isRegistering = true);

    try {
      final employeeData = {
        'first_name': _firstNameController.text,
        'last_name': _lastNameController.text,
        'position': _positionController.text,
        'email': _emailController.text,
        'contact_number': _contactController.text,
        'address': _addressController.text,
      };

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Registering Employee & Processing Faces..."),
            duration: Duration(seconds: 2),
          ),
        );
      }

      await _supabaseService.registerEmployeeWithPhotos(
        employeeData,
        _capturedImagePaths,
      );

      if (mounted) {
        await _soundService.playSuccess(message: "Registration Successful");

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text("Success"),
            content: const Text(
              "Employee registered with multi-angle face data.",
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx); // Close dialog
                  Navigator.pop(context); // Close screen
                },
                child: const Text("OK"),
              ),
            ],
          ),
        );
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
            content: Text("Error: $errorMsg"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _positionController.dispose();
    _emailController.dispose();
    _contactController.dispose();
    _addressController.dispose();
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                const SizedBox(height: 30),

                // Photos Section
                if (_capturedImagePaths.isEmpty)
                  Container(
                    height: 150,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.grey.shade400,
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.face, size: 48, color: Colors.grey),
                          const SizedBox(height: 8),
                          const Text(
                            "No face data captured",
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 120,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _capturedImagePaths.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (ctx, index) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_capturedImagePaths[index]),
                            width: 100,
                            height: 100,
                            fit: BoxFit.cover,
                          ),
                        );
                      },
                    ),
                  ),

                const SizedBox(height: 16),

                if (_capturedImagePaths.isEmpty)
                  ElevatedButton.icon(
                    onPressed: _isRegistering ? null : _startMultiAngleCapture,
                    icon: const Icon(Icons.camera_enhance),
                    label: const Text("START FACE SCAN"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: _isRegistering ? null : _retakeFace,
                    icon: const Icon(Icons.refresh),
                    label: const Text("RETAKE SCAN"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),

                const SizedBox(height: 40),
                ElevatedButton(
                  onPressed: _isRegistering ? null : _submitRegistration,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    backgroundColor: Colors.blue[900],
                    foregroundColor: Colors.white,
                  ),
                  child: _isRegistering
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          "COMPLETE REGISTRATION",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
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
}
