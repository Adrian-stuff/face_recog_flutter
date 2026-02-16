import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/face_service.dart';
import '../services/liveness_service.dart';
import '../widgets/camera_view.dart';
import '../widgets/oval_face_mask.dart';

/// Full-screen liveness challenge.
///
/// Opens the front camera, guides the user through:
///   1. Face positioning  →  2. Blink  →  3. Colour challenge
///
/// On success it takes a still photo and pops with the file path.
/// On timeout / failure it pops with `null`.
class LivenessCheckScreen extends StatefulWidget {
  const LivenessCheckScreen({super.key});

  @override
  State<LivenessCheckScreen> createState() => _LivenessCheckScreenState();
}

class _LivenessCheckScreenState extends State<LivenessCheckScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  final FaceService _faceService = FaceService();
  final LivenessService _liveness = LivenessService();

  bool _isDetecting = false;
  bool _cameraReady = false;
  String? _errorMessage;
  double? _originalBrightness;
  Timer? _timeoutTimer;

  // Animation for the oval border pulse.
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  static const Duration _timeout = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initCamera();
    _setMaxBrightness();
    WakelockPlus.enable(); // Keep screen on
  }

  Future<void> _setMaxBrightness() async {
    try {
      _originalBrightness = await ScreenBrightness().current;
      await ScreenBrightness().setScreenBrightness(1.0);
      debugPrint('Screen brightness set to max');
    } catch (e) {
      debugPrint('Could not set screen brightness: $e');
    }
  }

  Future<void> _restoreBrightness() async {
    try {
      if (_originalBrightness != null) {
        await ScreenBrightness().setScreenBrightness(_originalBrightness!);
      } else {
        await ScreenBrightness().resetScreenBrightness();
      }
    } catch (e) {
      debugPrint('Could not restore screen brightness: $e');
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      await _faceService.initialize();

      await _cameraController!.initialize();
      await _faceService.initialize();

      if (!mounted) return;
      setState(() => _cameraReady = true);

      _startStream();
      _timeoutTimer = Timer(_timeout, _onTimeout);
    } catch (e) {
      debugPrint('LivenessCheck camera init error: $e');
      if (mounted) Navigator.pop(context, null);
    }
  }

  // ─────────────── Image stream ───────────────

  void _startStream() {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _cameraController!.value.isStreamingImages) {
      return;
    }

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isDetecting) return;
      _isDetecting = true;

      try {
        final rotation = _cameraController!.description.sensorOrientation;
        final result = await _faceService.processImage(image, rotation);

        final error = result['error'] as String?;
        Face? face;

        if (error != null) {
          // Show user-facing message for multiple faces.
          if (mounted) {
            setState(() {
              _errorMessage = error == 'Multiple faces detected'
                  ? 'Only one face allowed'
                  : null;
            });
          }
        } else {
          face = result['face'] as Face?;
          if (mounted && _errorMessage != null) {
            setState(() => _errorMessage = null);
          }
        }

        // Compute face brightness for colour challenge.
        double? brightness;
        if (face != null && _liveness.phase == LivenessPhase.colorChallenge) {
          brightness = await _computeFaceBrightness(image, face, rotation);
        }

        final phase = _liveness.update(face: face, faceBrightness: brightness);

        if (mounted) setState(() {});

        if (phase == LivenessPhase.passed) {
          await _onPassed();
        }
      } catch (e) {
        debugPrint('LivenessCheck frame error: $e');
      } finally {
        _isDetecting = false;
      }
    });
  }

  // ─────────────── Brightness helper ───────────────

  /// Computes the average brightness (luma) of the face bounding-box
  /// directly from the Y plane of the YUV camera image.  This is very
  /// cheap — no colour conversion needed.
  Future<double> _computeFaceBrightness(
    CameraImage image,
    Face face,
    int rotation,
  ) async {
    return await compute<_BrightnessData, double>(
      _computeBrightnessIsolate,
      _BrightnessData(
        yPlane: image.planes[0].bytes,
        yRowStride: image.planes[0].bytesPerRow,
        imageWidth: image.width,
        imageHeight: image.height,
        faceBox: face.boundingBox,
        rotation: rotation,
      ),
    );
  }

  // ─────────────── Phase handlers ───────────────

  Future<void> _onPassed() async {
    _timeoutTimer?.cancel();

    try {
      // Stop the stream before taking a picture.
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }

      final photo = await _cameraController!.takePicture();
      if (mounted) Navigator.pop(context, photo.path);
    } catch (e) {
      debugPrint('LivenessCheck capture error: $e');
      if (mounted) Navigator.pop(context, null);
    }
  }

  void _onTimeout() {
    if (mounted) {
      setState(() {
        // Let the user see the message briefly before closing.
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Liveness check timed out. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.pop(context, null);
    }
  }

  // ─────────────── Build ───────────────

  @override
  Widget build(BuildContext context) {
    if (!_cameraReady || _cameraController == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final phase = _liveness.phase;

    // Determine oval border colour from phase.
    Color borderColor;
    switch (phase) {
      case LivenessPhase.positionFace:
        borderColor = Colors.white;
        break;
      case LivenessPhase.blink:
        borderColor = Colors.amber;
        break;
      case LivenessPhase.colorChallenge:
        borderColor = _liveness.currentChallengeColor;
        break;
      case LivenessPhase.passed:
        borderColor = Colors.greenAccent;
        break;
      case LivenessPhase.failed:
        borderColor = Colors.red;
        break;
    }

    // Determine challenge tint.
    Color? challengeColor;
    if (phase == LivenessPhase.colorChallenge) {
      challengeColor = _liveness.currentChallengeColor;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview (full-screen).
          CameraView(controller: _cameraController!),

          // Oval mask overlay.
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return OvalFaceMask(
                borderColor: borderColor.withAlpha(
                  (255 * _pulseAnimation.value).toInt(),
                ),
                challengeColor: challengeColor,
                onOvalRect: (rect) {
                  _liveness.ovalRect = rect;
                },
              );
            },
          ),

          // Instruction / error text.
          Positioned(
            bottom: 120,
            left: 24,
            right: 24,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Container(
                key: ValueKey(_errorMessage ?? phase.toString()),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(180),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _errorMessage != null
                        ? Colors.red.withAlpha(160)
                        : borderColor.withAlpha(100),
                    width: 1,
                  ),
                ),
                child: Text(
                  _errorMessage ?? _liveness.instruction,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _errorMessage != null
                        ? Colors.redAccent
                        : Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ),

          // Close button.
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context, null),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _pulseController.dispose();
    _cameraController?.dispose();
    _restoreBrightness();
    WakelockPlus.disable(); // Allow screen to sleep again
    super.dispose();
  }
}

// ─────────────── Isolate helpers ───────────────

class _BrightnessData {
  final Uint8List yPlane;
  final int yRowStride;
  final int imageWidth;
  final int imageHeight;
  final Rect faceBox;
  final int rotation;

  _BrightnessData({
    required this.yPlane,
    required this.yRowStride,
    required this.imageWidth,
    required this.imageHeight,
    required this.faceBox,
    required this.rotation,
  });
}

/// Isolate function — compute average brightness from Y plane.
double _computeBrightnessIsolate(_BrightnessData data) {
  // Face bounding box coordinates are in the *rotated* image space
  // (i.e. the orientation ML Kit sees). The Y plane is stored in the
  // camera's native orientation, so we need to use the raw coordinates.
  final left = data.faceBox.left.toInt().clamp(0, data.imageWidth - 1);
  final top = data.faceBox.top.toInt().clamp(0, data.imageHeight - 1);
  final right = data.faceBox.right.toInt().clamp(0, data.imageWidth);
  final bottom = data.faceBox.bottom.toInt().clamp(0, data.imageHeight);

  if (right <= left || bottom <= top) return 128.0;

  double sum = 0;
  int count = 0;

  // Sample every 2nd pixel for speed.
  for (int y = top; y < bottom; y += 2) {
    for (int x = left; x < right; x += 2) {
      final idx = y * data.yRowStride + x;
      if (idx < data.yPlane.length) {
        sum += data.yPlane[idx];
        count++;
      }
    }
  }

  return count > 0 ? sum / count : 128.0;
}
