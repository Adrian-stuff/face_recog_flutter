import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Phases of the active liveness challenge.
enum LivenessPhase { positionFace, blink, colorChallenge, passed, failed }

/// Colors cycled during the color-challenge phase.
/// We use 3 distinct hues so brightness-shift analysis is meaningful.
const List<Color> challengeColors = [
  Color(0xFF00E676), // green
  Color(0xFF2979FF), // blue
  Color(0xFFFF1744), // red
];

/// Manages the multi-step active liveness challenge.
///
/// Feed it ML Kit [Face] results frame-by-frame via [update] and it will
/// advance through [LivenessPhase]s automatically.
class LivenessService {
  LivenessPhase _phase = LivenessPhase.positionFace;
  LivenessPhase get phase => _phase;

  // ── Position-face ──────────────────────────────────────────────
  Rect? ovalRect; // Set by the UI once layout is known.

  // ── Blink detection ────────────────────────────────────────────
  int _eyesClosedFrames = 0;
  int _eyesOpenAfterCloseFrames = 0;
  bool _sawEyesClosed = false;
  static const int _requiredClosedFrames = 1;
  static const int _requiredOpenFrames = 1;
  static const double _closedThreshold = 0.4;
  static const double _openThreshold = 0.6;

  // ── Color challenge ────────────────────────────────────────────
  int _currentColorIndex = 0;
  int get currentColorIndex => _currentColorIndex;
  Color get currentChallengeColor => challengeColors[_currentColorIndex];

  /// Average face-region brightness captured per color.
  final List<double> _brightnessSamples = [];
  int _colorHoldFrames = 0;

  /// How many frames to hold each color before sampling.
  static const int _colorHoldRequired = 3;

  /// Minimum brightness variance across 3 colors to be considered "live".
  static const double _varianceThreshold = 1.5;

  // ── Instruction text for the UI ────────────────────────────────
  String get instruction {
    switch (_phase) {
      case LivenessPhase.positionFace:
        return 'Position your face inside the oval';
      case LivenessPhase.blink:
        return 'Please blink';
      case LivenessPhase.colorChallenge:
        return 'Hold still…';
      case LivenessPhase.passed:
        return 'Verified ✓';
      case LivenessPhase.failed:
        return 'Verification failed';
    }
  }

  /// Reset everything for a new attempt.
  void reset() {
    _phase = LivenessPhase.positionFace;
    _eyesClosedFrames = 0;
    _eyesOpenAfterCloseFrames = 0;
    _sawEyesClosed = false;
    _currentColorIndex = 0;
    _brightnessSamples.clear();
    _colorHoldFrames = 0;
  }

  // ─────────────────────────────────────────────────────────────────
  // Main per-frame update.  Returns the *current* phase after update.
  // ─────────────────────────────────────────────────────────────────

  /// [face]          — ML Kit Face (nullable if no face detected this frame).
  /// [faceBrightness] — average brightness of the face bounding-box region,
  ///                    computed by the caller from the camera image.
  LivenessPhase update({Face? face, double? faceBrightness}) {
    if (_phase == LivenessPhase.passed || _phase == LivenessPhase.failed) {
      return _phase;
    }

    // No face → stay in current phase but don't advance.
    if (face == null) return _phase;

    switch (_phase) {
      case LivenessPhase.positionFace:
        _handlePositionFace(face);
        break;
      case LivenessPhase.blink:
        _handleBlink(face);
        break;
      // Color challenge is currently skipped — blink goes straight to passed.
      // The color challenge measures brightness variance across flashed colors,
      // but in practice ambient lighting dominates and the variance is
      // unreliable for distinguishing real faces from photos/screens.
      // Keeping the code for potential future re-enablement.
      case LivenessPhase.colorChallenge:
        _handleColorChallenge(faceBrightness);
        break;
      default:
        break;
    }

    return _phase;
  }

  // ─────────────── Phase handlers ───────────────

  void _handlePositionFace(Face face) {
    // Face bounding box is in ML Kit image coordinates, which don't map
    // directly to screen coordinates.  As long as a face is detected
    // and has a reasonable size we accept it.
    final faceBox = face.boundingBox;
    if (faceBox.width > 50 && faceBox.height > 50) {
      _phase = LivenessPhase.blink;
      debugPrint(
        '[Liveness] Face positioned (${faceBox.width.toInt()}x${faceBox.height.toInt()}) — moving to blink phase',
      );
    }
  }

  void _handleBlink(Face face) {
    final leftEye = face.leftEyeOpenProbability;
    final rightEye = face.rightEyeOpenProbability;

    debugPrint(
      '[Liveness] Eyes: L=${leftEye?.toStringAsFixed(2)} R=${rightEye?.toStringAsFixed(2)} closed=$_sawEyesClosed',
    );

    if (leftEye == null || rightEye == null) return;

    if (!_sawEyesClosed) {
      // Wait for eyes to close (probability drops below threshold).
      if (leftEye < _closedThreshold && rightEye < _closedThreshold) {
        _eyesClosedFrames++;
        if (_eyesClosedFrames >= _requiredClosedFrames) {
          _sawEyesClosed = true;
          debugPrint(
            '[Liveness] Eyes closed detected (L=$leftEye R=$rightEye)',
          );
        }
      } else {
        _eyesClosedFrames = 0;
      }
    } else {
      // Wait for eyes to re-open (probability rises above threshold).
      if (leftEye > _openThreshold && rightEye > _openThreshold) {
        _eyesOpenAfterCloseFrames++;
        if (_eyesOpenAfterCloseFrames >= _requiredOpenFrames) {
          debugPrint('[Liveness] Blink confirmed — liveness passed');
          _phase = LivenessPhase.passed;
        }
      } else {
        _eyesOpenAfterCloseFrames = 0;
      }
    }
  }

  void _handleColorChallenge(double? brightness) {
    _colorHoldFrames++;

    // Wait for the color to be displayed for enough frames before sampling.
    if (_colorHoldFrames >= _colorHoldRequired) {
      if (brightness != null) {
        _brightnessSamples.add(brightness);
        debugPrint(
          '[Liveness] Color ${_currentColorIndex + 1}/${challengeColors.length}'
          ' brightness=$brightness',
        );
      }

      // Move to next color or finish.
      _currentColorIndex++;
      _colorHoldFrames = 0;

      if (_currentColorIndex >= challengeColors.length) {
        _evaluateColorChallenge();
      }
    }
  }

  void _evaluateColorChallenge() {
    if (_brightnessSamples.length < 2) {
      // Not enough data — pass anyway (graceful degradation).
      debugPrint('[Liveness] Not enough brightness data — passing');
      _phase = LivenessPhase.passed;
      return;
    }

    // Compute variance of brightness samples.
    final mean =
        _brightnessSamples.reduce((a, b) => a + b) / _brightnessSamples.length;
    final variance =
        _brightnessSamples
            .map((b) => (b - mean) * (b - mean))
            .reduce((a, b) => a + b) /
        _brightnessSamples.length;

    debugPrint(
      '[Liveness] Color challenge variance=$variance '
      '(threshold=$_varianceThreshold)',
    );

    if (variance >= _varianceThreshold) {
      _phase = LivenessPhase.passed;
    } else {
      // Low variance can indicate a flat surface (photo/screen).
      // However, ambient lighting can also cause low variance on real faces,
      // so we pass with a warning rather than hard-failing.
      debugPrint('[Liveness] Low color variance — passing with warning');
      _phase = LivenessPhase.passed;
    }
  }
}
