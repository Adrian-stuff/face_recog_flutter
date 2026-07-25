// AUTO-GENERATED from shared/kiosk-config.json by shared/generate-configs.mjs.
// Do not edit by hand — edit kiosk-config.json and re-run the generator.

// ignore_for_file: constant_identifier_names
import 'package:flutter/widgets.dart' show Color;

/// Gestures used by the liveness challenge, in the canonical shared order.
/// Kept as a Dart enum (rather than importing the JSON list directly) so
/// call sites get compile-time exhaustiveness checking, same as before.
enum LivenessGesture {
  blink,
  smile,
  turnLeft,
  turnRight,
}

/// sRGB equivalents of the web app's actual DaisyUI "ledger" theme brand
/// colors (app/globals.css / DESIGN.md), so the kiosk screens use the same
/// brand palette as the web kiosk instead of generic Material defaults.
/// Apply opacity/shades at the call site as needed, e.g.
/// `KioskColors.success.withValues(alpha: 0.1)`, the same way the
/// built-in Colors.* palette is normally used.
class KioskColors {
  KioskColors._();

  static const Color base100 = Color(0xFFFFFFFF);
  static const Color base200 = Color(0xFFF6F6FB);
  static const Color base300 = Color(0xFFF0EFF5);
  static const Color baseContent = Color(0xFF1A1921);
  static const Color primary = Color(0xFF5F49AB);
  static const Color primaryHover = Color(0xFF50349C);
  static const Color secondary = Color(0xFF009D9E);
  static const Color accent = Color(0xFF009D9E);
  static const Color neutral = Color(0xFF3A3942);
  static const Color info = Color(0xFF009D9E);
  static const Color success = Color(0xFF308639);
  static const Color warning = Color(0xFFBB6A00);
  static const Color error = Color(0xFFC53637);
  static const Color hairline = Color(0xFFDEDDE3);
  static const Color muted = Color(0xFF63626A);
}

/// px equivalents of app/globals.css's --radius-* tokens.
class KioskRadii {
  KioskRadii._();

  static const double selectorPx = 999;
  static const double fieldPx = 6;
  static const double boxPx = 10;
}

class KioskConfig {
  KioskConfig._();

  static const int perGestureTimeoutMs = 8000;
  static const double eyeBlinkThresholdLow = 0.45;
  static const double eyeBlinkThresholdHigh = 0.55;
  static const double smileThresholdLow = 0.4;
  static const double smileThresholdHigh = 0.75;
  static const double turnThresholdDeg = 15;
  static const double turnCenterThresholdDeg = 8;

  static const double localMatchThreshold = 0.6;
  static const double serverMatchThreshold = 0.6;
  static const int serverMatchCount = 5;
}

class KioskStrings {
  KioskStrings._();

  static const String whoAreYou = "Who are you?";
  static const String searchPlaceholder = "Search your name…";
  static const String notYou = "Not you?";
  static const String lookAtCamera = "Look at the camera";
  static const String positionFace = "Position your face inside the oval";
  static const String gestureGetReady = "Get ready…";
  static const String gestureBlink = "Please blink";
  static const String gestureSmile = "Please smile";
  static const String gestureTurnLeft = "Turn your head left";
  static const String gestureTurnRight = "Turn your head right";
  static const String verifying = "Verifying…";
  static const String passed = "Verified";
  static const String failed = "Verification failed";
  static const String recordingAttendance = "Recording attendance…";
  static const String tryAgain = "Try Again";
  static const String pickAgain = "Pick Again";
  static const String cameraAccessRequired = "Camera access is required.";
  static const String cameraAccessInstructions = "Please allow camera access in your browser settings and reload this page.";
  static const String networkError = "Network error — please try again.";
  static const String faceNotRecognized = "Face not recognized. Please try again.";
  static const String faceNotRecognizedSeeAdmin = "Face not recognized. Please see your administrator.";
  static const String faceDoesNotMatch = "Face does not match the selected employee. Please try again or select the correct employee.";
}
