import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../config/kiosk_config.generated.dart';
// Re-exported so existing consumers of this file (liveness_check_screen.dart,
// test/liveness_service_test.dart) keep seeing LivenessGesture without each
// needing its own import of the generated config — it used to be defined
// here directly.
export '../config/kiosk_config.generated.dart' show LivenessGesture;

/// Phases of the active liveness challenge.
enum LivenessPhase { positionFace, gesture, colorChallenge, passed, failed }

// LivenessGesture and the thresholds/timing below come from
// KioskConfig/KioskStrings (lib/config/kiosk_config.generated.dart),
// generated from the payroll-system repo's shared/kiosk-config.json — the
// single source of truth also consumed by the Next.js web kiosk, so the
// two platforms can't silently drift out of sync. Edit that JSON file and
// re-run shared/generate-configs.mjs, don't hand-edit values here.
//
// A fresh gesture is drawn per attempt so a replayed video of a single
// past gesture can't be pre-recorded and reused for the next check-in.

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
  LivenessService({Random? random}) : _rng = random ?? Random();

  final Random _rng;

  LivenessPhase _phase = LivenessPhase.positionFace;
  LivenessPhase get phase => _phase;

  // ── Position-face ──────────────────────────────────────────────
  Rect? ovalRect; // Set by the UI once layout is known.

  // ── Gesture selection ──────────────────────────────────────────
  LivenessGesture? _currentGesture;
  LivenessGesture? get currentGesture => _currentGesture;
  final List<LivenessGesture> _remainingGestures = [];
  DateTime? _gestureStartedAt;

  // If the current gesture hasn't completed in this long, assume it's not
  // working for this face/lighting/device (e.g. a device that never reports
  // a smilingProbability) and swap to a different randomly-chosen gesture
  // rather than stalling the whole check.
  static const Duration _perGestureTimeout = Duration(
    milliseconds: KioskConfig.perGestureTimeoutMs,
  );

  // ── Blink sub-state ────────────────────────────────────────────
  int _eyesClosedFrames = 0;
  int _eyesOpenAfterCloseFrames = 0;
  bool _sawEyesClosed = false;
  static const int _requiredClosedFrames = 1;
  static const int _requiredOpenFrames = 1;
  static const double _closedThreshold = KioskConfig.eyeBlinkThresholdLow;
  static const double _openThreshold = KioskConfig.eyeBlinkThresholdHigh;

  // ── Smile sub-state ────────────────────────────────────────────
  // Requires a neutral→smile transition (not just "is smiling") so a photo
  // of an already-smiling face doesn't trivially pass.
  int _neutralFrames = 0;
  int _smileFrames = 0;
  bool _sawNeutral = false;
  static const int _requiredNeutralFrames = 1;
  static const int _requiredSmileFrames = 1;
  static const double _neutralSmileThreshold = KioskConfig.smileThresholdLow;
  static const double _smileThreshold = KioskConfig.smileThresholdHigh;

  // ── Head-turn sub-state ────────────────────────────────────────
  // Requires turn-away-then-return-to-center, so a photo held at a fixed
  // angle doesn't satisfy it — only an actual turning motion does.
  int _turnedFrames = 0;
  int _returnedFrames = 0;
  bool _sawTurned = false;
  double? _lastHeadEulerAngleY;
  static const int _requiredTurnedFrames = 1;
  static const int _requiredReturnedFrames = 1;
  // Confirmed on a real device: positive headEulerAngleY = turned toward
  // the viewer's left (opposite of the usual ML Kit Flutter sample
  // convention — front camera mirroring varies by device/OEM camera stack).
  static const double _turnThreshold = KioskConfig.turnThresholdDeg;
  static const double _centerThreshold = KioskConfig.turnCenterThresholdDeg;

  // ── Color challenge (currently unused, see below) ──────────────
  int _currentColorIndex = 0;
  int get currentColorIndex => _currentColorIndex;
  Color get currentChallengeColor => challengeColors[_currentColorIndex];
  final List<double> _brightnessSamples = [];
  int _colorHoldFrames = 0;
  static const int _colorHoldRequired = 3;
  static const double _varianceThreshold = 1.5;

  // ── Instruction text for the UI ────────────────────────────────
  // Base strings (position/gesture prompts) come from KioskStrings, shared
  // with the web kiosk. The richer progressive turn feedback below ("Keep
  // turning...", "Almost there...") is a Flutter-specific enhancement on
  // top of that shared base, not currently replicated on web.
  String get instruction {
    switch (_phase) {
      case LivenessPhase.positionFace:
        return KioskStrings.positionFace;
      case LivenessPhase.gesture:
        return _gestureInstruction;
      case LivenessPhase.colorChallenge:
        return 'Hold still…';
      case LivenessPhase.passed:
        return '${KioskStrings.passed} ✓';
      case LivenessPhase.failed:
        return KioskStrings.failed;
    }
  }

  String get _gestureInstruction {
    switch (_currentGesture) {
      case LivenessGesture.blink:
        return KioskStrings.gestureBlink;
      case LivenessGesture.smile:
        return KioskStrings.gestureSmile;
      case LivenessGesture.turnLeft:
        return _turnInstruction(turnLeft: true);
      case LivenessGesture.turnRight:
        return _turnInstruction(turnLeft: false);
      case null:
        return KioskStrings.gestureGetReady;
    }
  }

  String _turnInstruction({required bool turnLeft}) {
    if (_sawTurned) return 'Great! Now return to center';

    final angle = _lastHeadEulerAngleY;
    final label = turnLeft ? 'left' : 'right';
    final facingWrongWay = angle == null || (turnLeft ? angle <= 0 : angle >= 0);
    if (facingWrongWay) {
      return turnLeft ? KioskStrings.gestureTurnLeft : KioskStrings.gestureTurnRight;
    }
    if (turnProgress < 0.5) return 'Keep turning $label...';
    return 'Almost there — a bit more $label';
  }

  /// How close the live head-turn angle is to satisfying the active turn
  /// gesture's threshold: 0.0 (facing the wrong way) to 1.0 (aligned).
  /// Only meaningful while [currentGesture] is turnLeft/turnRight — used to
  /// drive live "almost there" text and the directional arrow's glow.
  double get turnProgress {
    final angle = _lastHeadEulerAngleY;
    if (angle == null) return 0.0;
    if (_currentGesture == LivenessGesture.turnLeft) {
      return (angle / _turnThreshold).clamp(0.0, 1.0);
    }
    if (_currentGesture == LivenessGesture.turnRight) {
      return (-angle / _turnThreshold).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  /// Reset everything for a new attempt.
  void reset() {
    _phase = LivenessPhase.positionFace;
    _currentGesture = null;
    _remainingGestures.clear();
    _gestureStartedAt = null;
    _resetGestureSubState();
    _currentColorIndex = 0;
    _brightnessSamples.clear();
    _colorHoldFrames = 0;
  }

  void _resetGestureSubState() {
    _eyesClosedFrames = 0;
    _eyesOpenAfterCloseFrames = 0;
    _sawEyesClosed = false;
    _neutralFrames = 0;
    _smileFrames = 0;
    _sawNeutral = false;
    _turnedFrames = 0;
    _returnedFrames = 0;
    _sawTurned = false;
    _lastHeadEulerAngleY = null;
  }

  // ─────────────────────────────────────────────────────────────────
  // Main per-frame update.  Returns the *current* phase after update.
  // ─────────────────────────────────────────────────────────────────

  /// [face]          — ML Kit Face (nullable if no face detected this frame).
  /// [faceBrightness] — average brightness of the face bounding-box region,
  ///                    computed by the caller from the camera image.
  LivenessPhase update({Face? face, double? faceBrightness}) {
    return _updateInternal(
      faceWidth: face?.boundingBox.width,
      faceHeight: face?.boundingBox.height,
      leftEyeOpen: face?.leftEyeOpenProbability,
      rightEyeOpen: face?.rightEyeOpenProbability,
      smiling: face?.smilingProbability,
      headEulerAngleY: face?.headEulerAngleY,
      faceBrightness: faceBrightness,
    );
  }

  /// Same as [update] but takes raw values instead of a [Face], so the
  /// state machine can be exercised in tests without constructing ML Kit
  /// types.
  @visibleForTesting
  LivenessPhase updateForTest({
    double? faceWidth,
    double? faceHeight,
    double? leftEyeOpen,
    double? rightEyeOpen,
    double? smiling,
    double? headEulerAngleY,
    double? faceBrightness,
  }) {
    return _updateInternal(
      faceWidth: faceWidth,
      faceHeight: faceHeight,
      leftEyeOpen: leftEyeOpen,
      rightEyeOpen: rightEyeOpen,
      smiling: smiling,
      headEulerAngleY: headEulerAngleY,
      faceBrightness: faceBrightness,
    );
  }

  /// Test-only: force the gesture timeout clock into the past so a
  /// timeout-driven gesture swap can be exercised deterministically.
  @visibleForTesting
  void debugSetGestureStartedAt(DateTime time) {
    _gestureStartedAt = time;
  }

  /// Test-only: advance to the next queued gesture without waiting for a
  /// timeout, so tests can force a specific gesture to be active.
  @visibleForTesting
  void debugSkipToNextGesture() => _startNextGesture();

  @visibleForTesting
  DateTime? get debugGestureStartedAt => _gestureStartedAt;

  LivenessPhase _updateInternal({
    double? faceWidth,
    double? faceHeight,
    double? leftEyeOpen,
    double? rightEyeOpen,
    double? smiling,
    double? headEulerAngleY,
    double? faceBrightness,
  }) {
    if (_phase == LivenessPhase.passed || _phase == LivenessPhase.failed) {
      return _phase;
    }

    // No face → stay in current phase but don't advance.
    if (faceWidth == null || faceHeight == null) return _phase;

    switch (_phase) {
      case LivenessPhase.positionFace:
        _handlePositionFace(faceWidth, faceHeight);
        break;
      case LivenessPhase.gesture:
        _handleGesture(
          leftEyeOpen: leftEyeOpen,
          rightEyeOpen: rightEyeOpen,
          smiling: smiling,
          headEulerAngleY: headEulerAngleY,
        );
        break;
      // Color challenge is currently skipped — gestures go straight to passed.
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

  void _handlePositionFace(double faceWidth, double faceHeight) {
    // Face bounding box is in ML Kit image coordinates, which don't map
    // directly to screen coordinates.  As long as a face is detected
    // and has a reasonable size we accept it.
    if (faceWidth > 50 && faceHeight > 50) {
      _phase = LivenessPhase.gesture;
      _startNextGesture();
      debugPrint(
        '[Liveness] Face positioned (${faceWidth.toInt()}x${faceHeight.toInt()})'
        ' — starting gesture: $_currentGesture',
      );
    }
  }

  void _startNextGesture() {
    if (_remainingGestures.isEmpty) {
      _remainingGestures.addAll(LivenessGesture.values);
      _remainingGestures.shuffle(_rng);
    }
    _currentGesture = _remainingGestures.removeLast();
    _gestureStartedAt = DateTime.now();
    _resetGestureSubState();
  }

  void _handleGesture({
    double? leftEyeOpen,
    double? rightEyeOpen,
    double? smiling,
    double? headEulerAngleY,
  }) {
    final startedAt = _gestureStartedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) > _perGestureTimeout) {
      debugPrint(
        '[Liveness] "$_currentGesture" timed out — trying a different gesture',
      );
      _startNextGesture();
      return;
    }

    switch (_currentGesture!) {
      case LivenessGesture.blink:
        _handleBlink(leftEyeOpen, rightEyeOpen);
        break;
      case LivenessGesture.smile:
        _handleSmile(smiling);
        break;
      case LivenessGesture.turnLeft:
        _handleTurn(headEulerAngleY, turnLeft: true);
        break;
      case LivenessGesture.turnRight:
        _handleTurn(headEulerAngleY, turnLeft: false);
        break;
    }
  }

  void _handleBlink(double? leftEye, double? rightEye) {
    debugPrint(
      '[Liveness] Eyes: L=${leftEye?.toStringAsFixed(2)} R=${rightEye?.toStringAsFixed(2)} closed=$_sawEyesClosed',
    );

    if (leftEye == null || rightEye == null) return;

    if (!_sawEyesClosed) {
      // Wait for eyes to close (probability drops below threshold).
      if (leftEye < _closedThreshold || rightEye < _closedThreshold) {
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
      if (leftEye > _openThreshold || rightEye > _openThreshold) {
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

  void _handleSmile(double? smiling) {
    debugPrint(
      '[Liveness] Smile: ${smiling?.toStringAsFixed(2)} sawNeutral=$_sawNeutral',
    );

    if (smiling == null) return;

    if (!_sawNeutral) {
      if (smiling < _neutralSmileThreshold) {
        _neutralFrames++;
        if (_neutralFrames >= _requiredNeutralFrames) {
          _sawNeutral = true;
          debugPrint('[Liveness] Neutral expression detected');
        }
      } else {
        _neutralFrames = 0;
      }
    } else {
      if (smiling > _smileThreshold) {
        _smileFrames++;
        if (_smileFrames >= _requiredSmileFrames) {
          debugPrint('[Liveness] Smile confirmed — liveness passed');
          _phase = LivenessPhase.passed;
        }
      } else {
        _smileFrames = 0;
      }
    }
  }

  void _handleTurn(double? headEulerAngleY, {required bool turnLeft}) {
    debugPrint(
      '[Liveness] HeadY: ${headEulerAngleY?.toStringAsFixed(1)} turnLeft=$turnLeft sawTurned=$_sawTurned',
    );

    if (headEulerAngleY == null) return;
    _lastHeadEulerAngleY = headEulerAngleY;

    final isTurnedCorrectDirection = turnLeft
        ? headEulerAngleY > _turnThreshold
        : headEulerAngleY < -_turnThreshold;

    if (!_sawTurned) {
      if (isTurnedCorrectDirection) {
        _turnedFrames++;
        if (_turnedFrames >= _requiredTurnedFrames) {
          _sawTurned = true;
          debugPrint('[Liveness] Head turn detected (angle=$headEulerAngleY)');
        }
      } else {
        _turnedFrames = 0;
      }
    } else {
      if (headEulerAngleY.abs() < _centerThreshold) {
        _returnedFrames++;
        if (_returnedFrames >= _requiredReturnedFrames) {
          debugPrint('[Liveness] Head returned to center — liveness passed');
          _phase = LivenessPhase.passed;
        }
      } else {
        _returnedFrames = 0;
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
