import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/liveness_service.dart';

void main() {
  group('LivenessService', () {
    test('positions face then starts a randomized gesture', () {
      final service = LivenessService(random: Random(1));
      expect(service.phase, LivenessPhase.positionFace);

      service.updateForTest(faceWidth: 200, faceHeight: 200);

      expect(service.phase, LivenessPhase.gesture);
      expect(service.currentGesture, isNotNull);
    });

    test('blink gesture passes on close-then-open transition', () {
      final service = _forceGesture(LivenessGesture.blink);

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        leftEyeOpen: 0.1,
        rightEyeOpen: 0.1,
      );
      expect(service.phase, LivenessPhase.gesture);

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        leftEyeOpen: 0.9,
        rightEyeOpen: 0.9,
      );
      expect(service.phase, LivenessPhase.passed);
    });

    test('smile gesture requires neutral before smiling', () {
      final service = _forceGesture(LivenessGesture.smile);

      // Already smiling with no neutral baseline first — must not pass yet.
      service.updateForTest(faceWidth: 200, faceHeight: 200, smiling: 0.9);
      expect(service.phase, LivenessPhase.gesture);

      service.updateForTest(faceWidth: 200, faceHeight: 200, smiling: 0.9);
      expect(service.phase, LivenessPhase.gesture);
    });

    test('smile gesture passes on neutral-then-smile transition', () {
      final service = _forceGesture(LivenessGesture.smile);

      service.updateForTest(faceWidth: 200, faceHeight: 200, smiling: 0.1);
      service.updateForTest(faceWidth: 200, faceHeight: 200, smiling: 0.9);

      expect(service.phase, LivenessPhase.passed);
    });

    test('turnLeft gesture passes on turn-then-return-to-center', () {
      final service = _forceGesture(LivenessGesture.turnLeft);

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: 25,
      );
      expect(service.phase, LivenessPhase.gesture);

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: 0,
      );
      expect(service.phase, LivenessPhase.passed);
    });

    test('turnProgress tracks live angle toward the target', () {
      final service = _forceGesture(LivenessGesture.turnLeft);

      expect(service.turnProgress, 0.0); // no face data yet
      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: -5, // wrong direction for turnLeft
      );
      expect(service.turnProgress, 0.0);

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: 7.5, // halfway to the 15 threshold
      );
      expect(service.turnProgress, closeTo(0.5, 0.01));

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: 30, // past the threshold — clamps to 1.0
      );
      expect(service.turnProgress, 1.0);
    });

    test('turnRight gesture ignores a turn in the wrong direction', () {
      final service = _forceGesture(LivenessGesture.turnRight);

      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: 25, // wrong direction (that's "left")
      );
      service.updateForTest(
        faceWidth: 200,
        faceHeight: 200,
        headEulerAngleY: 0,
      );
      expect(service.phase, LivenessPhase.gesture);
    });

    test('a stuck gesture times out and retries with a new attempt', () {
      final service = _forceGesture(LivenessGesture.smile);

      // No smilingProbability ever arrives (e.g. classification unavailable
      // on this device) — the gesture can never complete on its own.
      final past = DateTime.now().subtract(const Duration(seconds: 30));
      service.debugSetGestureStartedAt(past);

      service.updateForTest(faceWidth: 200, faceHeight: 200, smiling: null);

      expect(service.phase, LivenessPhase.gesture);
      // The timeout must have fired a fresh gesture attempt rather than
      // silently stalling on the same dead clock forever.
      expect(service.debugGestureStartedAt!.isAfter(past), isTrue);
    });

    test('does not regress phase when no face is present', () {
      final service = LivenessService(random: Random(1));
      final result = service.updateForTest();
      expect(result, LivenessPhase.positionFace);
    });
  });
}

/// Drives a fresh [LivenessService] into [LivenessPhase.gesture] with a
/// specific gesture selected, regardless of what the RNG would have picked.
LivenessService _forceGesture(LivenessGesture gesture) {
  final service = LivenessService(random: Random(1));
  service.updateForTest(faceWidth: 200, faceHeight: 200);
  while (service.currentGesture != gesture) {
    service.debugSkipToNextGesture();
  }
  return service;
}
