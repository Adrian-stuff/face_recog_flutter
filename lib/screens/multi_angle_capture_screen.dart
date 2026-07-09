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

enum CaptureStep { liveness, center, left, right, up, down, completed }

class MultiAngleCaptureScreen extends StatefulWidget {
  const MultiAngleCaptureScreen({super.key});

  @override
  State<MultiAngleCaptureScreen> createState() =>
      _MultiAngleCaptureScreenState();
}

class _MultiAngleCaptureScreenState extends State<MultiAngleCaptureScreen>
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

  static const Duration _timeout = Duration(
    seconds: 120,
  ); // Longer timeout for full process

  // Multi-Angle State
  CaptureStep _captureStep = CaptureStep.liveness;
  final Map<CaptureStep, String> _capturedImages = {};

  // Angle Thresholds (Degrees)
  // Note: Values depend on camera sensor orientation and mirroring
  static const double _yawThreshold = 20.0;
  static const double _pitchThreshold = 10.0;

  // Stability check
  int _stableFrames = 0;
  static const int _requiredStableFrames = 10;

  // Live angle readout, updated every frame so the instruction text and
  // directional arrow can react to the user's motion in real time instead
  // of only reporting a binary "aligned or not" once they cross the
  // threshold.
  double _currentYaw = 0;
  double _currentPitch = 0;

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

      if (!mounted) return;
      setState(() => _cameraReady = true);

      _startStream();
      _timeoutTimer = Timer(_timeout, _onTimeout);
    } catch (e) {
      debugPrint('MultiAngleCapture camera init error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Camera error: $e')));
        Navigator.pop(context, null);
      }
    }
  }

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

        if (_captureStep == CaptureStep.liveness) {
          // --- Phase 1: Liveness Check ---
          double? brightness;
          if (face != null && _liveness.phase == LivenessPhase.colorChallenge) {
            // brightness = await _computeFaceBrightness(image, face, rotation);
            // Skipping color challenge for now as per original
          }

          final phase = _liveness.update(
            face: face,
            faceBrightness: brightness,
          );

          if (mounted) setState(() {});

          if (phase == LivenessPhase.passed) {
            // Transition to Multi-Angle Capture
            setState(() {
              _captureStep = CaptureStep.center;
              _stableFrames = 0;
            });
          }
        } else if (_captureStep != CaptureStep.completed && face != null) {
          // --- Phase 2: Multi-Angle Capture ---
          _checkAngleAndCapture(face);
        }
      } catch (e) {
        debugPrint('Frame processing error: $e');
      } finally {
        _isDetecting = false;
      }
    });
  }

  void _checkAngleAndCapture(Face face) async {
    double yaw = face.headEulerAngleY ?? 0;
    double pitch = face.headEulerAngleX ?? 0;

    bool isAligned = false;

    switch (_captureStep) {
      case CaptureStep.center:
        isAligned = yaw.abs() < 10 && pitch.abs() < 10;
        break;
      case CaptureStep.left:
        // Turning Head LEFT means Yaw increases (Positive) usually (in mirrored front cam)
        // Need to verify standard. Usually:
        // Look Left -> Yaw Positive
        // Look Right -> Yaw Negative
        isAligned = yaw > _yawThreshold;
        break;
      case CaptureStep.right:
        isAligned = yaw < -_yawThreshold;
        break;
      case CaptureStep.up:
        isAligned = pitch > _pitchThreshold;
        break;
      case CaptureStep.down:
        isAligned = pitch < -_pitchThreshold;
        break;
      default:
        break;
    }

    // Update the live readout every frame (not just on alignment changes)
    // so the instruction text and directional arrow can track the user's
    // motion continuously, not just jump when they cross the threshold.
    _currentYaw = yaw;
    _currentPitch = pitch;

    if (isAligned) {
      _stableFrames++;
      if (mounted) setState(() {}); // Trigger refresh for progress/feedback

      if (_stableFrames >= _requiredStableFrames) {
        await _captureImageForStep(_captureStep);
        _advanceStep();
      }
    } else {
      _stableFrames = 0;
      if (mounted) setState(() {});
    }
  }

  /// How close the current yaw/pitch is to satisfying the active step's
  /// threshold: 0.0 (facing the wrong way / just starting) to 1.0 (aligned).
  /// Drives the live "almost there" text and the directional arrow's glow.
  double get _stepAngleProgress {
    switch (_captureStep) {
      case CaptureStep.left:
        return (_currentYaw / _yawThreshold).clamp(0.0, 1.0);
      case CaptureStep.right:
        return (-_currentYaw / _yawThreshold).clamp(0.0, 1.0);
      case CaptureStep.up:
        return (_currentPitch / _pitchThreshold).clamp(0.0, 1.0);
      case CaptureStep.down:
        return (-_currentPitch / _pitchThreshold).clamp(0.0, 1.0);
      case CaptureStep.center:
        final offCenter = (_currentYaw.abs() + _currentPitch.abs()) / 2;
        return (1 - (offCenter / 10)).clamp(0.0, 1.0);
      default:
        return 0.0;
    }
  }

  IconData? get _directionIcon {
    switch (_captureStep) {
      case CaptureStep.left:
        return Icons.chevron_left;
      case CaptureStep.right:
        return Icons.chevron_right;
      case CaptureStep.up:
        return Icons.keyboard_arrow_up;
      case CaptureStep.down:
        return Icons.keyboard_arrow_down;
      default:
        return null;
    }
  }

  void _advanceStep() {
    setState(() {
      _stableFrames = 0;
      switch (_captureStep) {
        case CaptureStep.center:
          _captureStep = CaptureStep.left;
          break;
        case CaptureStep.left:
          _captureStep = CaptureStep.right;
          break;
        case CaptureStep.right:
          _captureStep = CaptureStep.up;
          break;
        case CaptureStep.up:
          _captureStep = CaptureStep.down;
          break;
        case CaptureStep.down:
          _captureStep = CaptureStep.completed;
          _finish();
          break;
        default:
          break;
      }
    });
  }

  Future<void> _captureImageForStep(CaptureStep step) async {
    try {
      // We need to stop stream directly?
      // No, stopping/starting stream is slow. taking picture is acceptable.
      // But takePicture might conflict with startImageStream on some devices.
      // Ideally we pause stream -> take pic -> resume.
      // But for speed, let's try the "stop stream -> take pic -> restart" approach safely.

      await _cameraController!.stopImageStream();
      final photo = await _cameraController!.takePicture();
      _capturedImages[step] = photo.path;

      // Resume stream
      _startStream();
    } catch (e) {
      debugPrint("Error capturing step $step: $e");
    }
  }

  void _finish() {
    _timeoutTimer?.cancel();
    // Return a Map<String, String> where keys are step names (center, left, etc.)
    final result = _capturedImages.map((k, v) => MapEntry(k.name, v));
    Navigator.pop(context, result);
  }

  void _onTimeout() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session timed out.'),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.pop(context, null);
    }
  }

  String get _instruction {
    if (_errorMessage != null) return _errorMessage!;

    if (_captureStep == CaptureStep.liveness) {
      return _liveness.instruction;
    }

    if (_stableFrames > 0) return "Perfect! Hold still...";

    switch (_captureStep) {
      case CaptureStep.center:
        return "Look Straight Ahead";
      case CaptureStep.left:
        if (_currentYaw <= 0) return "Turn your head to the LEFT";
        if (_stepAngleProgress < 0.5) return "Keep turning LEFT...";
        return "Almost there — a bit more LEFT";
      case CaptureStep.right:
        if (_currentYaw >= 0) return "Turn your head to the RIGHT";
        if (_stepAngleProgress < 0.5) return "Keep turning RIGHT...";
        return "Almost there — a bit more RIGHT";
      case CaptureStep.up:
        if (_currentPitch <= 0) return "Tilt your head UP";
        if (_stepAngleProgress < 0.5) return "Keep tilting UP...";
        return "Almost there — a bit more UP";
      case CaptureStep.down:
        if (_currentPitch >= 0) return "Tilt your head DOWN";
        if (_stepAngleProgress < 0.5) return "Keep tilting DOWN...";
        return "Almost there — a bit more DOWN";
      case CaptureStep.completed:
        return "All Done!";
      default:
        return "";
    }
  }

  double get _progress {
    // 5 Steps total (Center, Left, Right, Up, Down)
    // + Liveness (0)
    if (_captureStep == CaptureStep.liveness) return 0.1;
    if (_captureStep == CaptureStep.completed) return 1.0;

    // index mapping
    // center: 0, left: 1, right: 2, up: 3, down: 4
    int idx = 0;
    switch (_captureStep) {
      case CaptureStep.center:
        idx = 0;
        break;
      case CaptureStep.left:
        idx = 1;
        break;
      case CaptureStep.right:
        idx = 2;
        break;
      case CaptureStep.up:
        idx = 3;
        break;
      case CaptureStep.down:
        idx = 4;
        break;
      default:
        break;
    }

    // Logic: base (0.2) + (step * 0.16)
    // 0: 0.2
    // 1: 0.36
    // ...
    // Also add stable frame progress?
    double stepProgress = idx / 5.0;
    double currentFrameProgress =
        (_stableFrames / _requiredStableFrames) * (1.0 / 5.0);

    return 0.2 + (stepProgress * 0.8) + currentFrameProgress;
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraReady || _cameraController == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // Border Color Logic
    Color borderColor = Colors.white;
    if (_captureStep == CaptureStep.liveness) {
      switch (_liveness.phase) {
        case LivenessPhase.positionFace:
          borderColor = Colors.white;
          break;
        case LivenessPhase.gesture:
          borderColor = Colors.amber;
          break;
        case LivenessPhase.passed:
          borderColor = Colors.greenAccent;
          break;
        default:
          borderColor = Colors.red;
      }
    } else {
      // Green if stabilizing
      if (_stableFrames > 0) {
        borderColor = Color.lerp(
          Colors.white,
          Colors.greenAccent,
          _stableFrames / _requiredStableFrames,
        )!;
      } else {
        borderColor = Colors.blueAccent;
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraView(controller: _cameraController!),

          // Oval Mask
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return OvalFaceMask(
                borderColor: borderColor.withAlpha(
                  (255 * _pulseAnimation.value).toInt(),
                ),
                onOvalRect: (rect) {
                  _liveness.ovalRect = rect;
                },
              );
            },
          ),

          // Directional arrow beside the oval — glows brighter as the user
          // turns closer to the target angle, so left/right/up/down have a
          // continuous visual cue instead of only a text label.
          if (_directionIcon != null && _liveness.ovalRect != null)
            _DirectionArrow(
              step: _captureStep,
              icon: _directionIcon!,
              progress: _stepAngleProgress,
              ovalRect: _liveness.ovalRect!,
            ),

          // Instruction
          Positioned(
            bottom: 120,
            left: 24,
            right: 24,
            child: Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    key: ValueKey(_instruction),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(180),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: borderColor.withAlpha(150),
                        width: 2,
                      ),
                    ),
                    child: Text(
                      _instruction,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (_directionIcon != null) ...[
                  const SizedBox(height: 12),
                  // Live "how close am I" gauge for the current angle step —
                  // distinct from the overall 5-step progress bar below, so
                  // the user sees moment-to-moment feedback while turning.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _stepAngleProgress,
                      backgroundColor: Colors.white.withAlpha(40),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color.lerp(
                          Colors.orangeAccent,
                          Colors.greenAccent,
                          _stepAngleProgress,
                        )!,
                      ),
                      minHeight: 6,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (_captureStep != CaptureStep.liveness)
                  // Progress Bar
                  LinearProgressIndicator(
                    value: _progress.clamp(0.0, 1.0),
                    backgroundColor: Colors.grey.withOpacity(0.3),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.greenAccent,
                    ),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
              ],
            ),
          ),

          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context, null),
            ),
          ),

          // Step Indicator (Debug-ish or helpful info)
          if (_captureStep != CaptureStep.liveness)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  "${_capturedImages.length} / 5 Captured",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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
    WakelockPlus.disable();
    super.dispose();
  }
}

/// Directional arrow positioned beside the face oval, pointing which way to
/// turn. Dims when the user is far from the target angle and brightens to
/// green as [progress] approaches 1.0, giving continuous feedback instead
/// of a single before/after state.
class _DirectionArrow extends StatelessWidget {
  const _DirectionArrow({
    required this.step,
    required this.icon,
    required this.progress,
    required this.ovalRect,
  });

  final CaptureStep step;
  final IconData icon;
  final double progress;
  final Rect ovalRect;

  static const double _size = 64;

  @override
  Widget build(BuildContext context) {
    double left;
    double top;
    switch (step) {
      case CaptureStep.left:
        left = ovalRect.left - _size - 8;
        top = ovalRect.center.dy - _size / 2;
        break;
      case CaptureStep.right:
        left = ovalRect.right + 8;
        top = ovalRect.center.dy - _size / 2;
        break;
      case CaptureStep.up:
        left = ovalRect.center.dx - _size / 2;
        top = ovalRect.top - _size - 8;
        break;
      case CaptureStep.down:
        left = ovalRect.center.dx - _size / 2;
        top = ovalRect.bottom + 8;
        break;
      default:
        left = ovalRect.center.dx - _size / 2;
        top = ovalRect.top - _size - 8;
    }

    final color = Color.lerp(Colors.white, Colors.greenAccent, progress)!;
    // Dim + shrink when far from the target, full-size and glowing once close.
    final opacity = 0.35 + (progress * 0.65);
    final scale = 0.8 + (progress * 0.3);

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: opacity,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 150),
            scale: scale,
            child: Icon(
              icon,
              size: _size,
              color: color,
              shadows: progress > 0.8
                  ? [Shadow(color: color, blurRadius: 16)]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
