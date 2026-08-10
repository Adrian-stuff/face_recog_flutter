import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// One permission the kiosk depends on, and what breaks without it.
class KioskPermission {
  final Permission permission;
  final String label;
  final String consequence;
  // Camera missing means the kiosk literally cannot scan a face; location
  // missing means WiFi/GPS checks silently degrade instead of hard-failing
  // (see NetworkGuard) — both worth surfacing, but only one of them is
  // "nothing works at all."
  final bool critical;

  const KioskPermission({
    required this.permission,
    required this.label,
    required this.consequence,
    required this.critical,
  });
}

/// Checks whether the OS permissions this app depends on are still granted.
///
/// Requesting a permission once at launch isn't enough on its own: Android
/// lets a user (or an MDM policy) revoke a granted permission at any time
/// from Settings without the app being told directly, and it never re-prompts
/// on its own. A denial here has real, sometimes confusing consequences —
/// see network_service.dart's getCurrentSSID(), which just returns null on a
/// denied location permission, so NetworkGuard reports "Incorrect WiFi
/// Network" even when the device is on the right network but the app simply
/// isn't allowed to check anymore. Surfacing the actual cause (and a
/// one-tap way to fix it) beats a kiosk that looks broken for a reason
/// nobody watching it can see.
class PermissionsService {
  static List<KioskPermission> get _tracked => [
    const KioskPermission(
      permission: Permission.camera,
      label: 'Camera',
      consequence: 'Employees cannot scan their face to time in or out.',
      critical: true,
    ),
    const KioskPermission(
      permission: Permission.location,
      label: 'Location',
      consequence:
          'The device cannot verify the office WiFi network or GPS location, '
          'which may block attendance or wrongly report the WiFi as incorrect.',
      critical: true,
    ),
    if (Platform.isAndroid)
      const KioskPermission(
        permission: Permission.notification,
        label: 'Notifications',
        consequence:
            'Background sync (uploading attendance while the app is closed) '
            'may run less reliably on this device.',
        critical: false,
      ),
  ];

  /// The tracked permissions that are currently NOT granted, most critical
  /// first. Checks current status only — never prompts, so this is safe to
  /// call on every resume without re-triggering the OS permission dialog.
  Future<List<KioskPermission>> checkMissing() async {
    final missing = <KioskPermission>[];
    for (final kp in _tracked) {
      final status = await kp.permission.status;
      if (!status.isGranted) {
        missing.add(kp);
      }
    }
    missing.sort((a, b) => a.critical == b.critical ? 0 : (a.critical ? -1 : 1));
    return missing;
  }

  /// Prompts for every tracked permission that isn't already granted.
  /// Skips ones already granted rather than requesting all unconditionally,
  /// so this is also safe to call again after the user comes back from
  /// Settings without re-prompting for ones they already fixed.
  Future<void> requestMissing() async {
    for (final kp in _tracked) {
      final status = await kp.permission.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        await kp.permission.request();
      }
    }
  }
}
