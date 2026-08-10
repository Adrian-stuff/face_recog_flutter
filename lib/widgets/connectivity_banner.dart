import 'package:flutter/material.dart';
import '../config/kiosk_config.generated.dart';
import '../services/supabase_service.dart';

/// Persistent "can't reach the server" strip, shown above whatever screen is
/// currently active (wired into MaterialApp.builder in app.dart) so it
/// survives navigation instead of only living on the kiosk screen.
///
/// Distinguishes the two failure modes SupabaseService already tracks
/// separately (isOnline vs pingServer): no radio at all, or a radio that's
/// associated but can't actually reach the server (captive portal, VPN,
/// server down). Neither state blocks the app — attendance is saved locally
/// either way — so this stays informational (KioskColors.warning), not an
/// error screen.
class ConnectivityBanner extends StatelessWidget {
  final ConnectivityStatus status;

  const ConnectivityBanner({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch (status) {
      ConnectivityStatus.noConnection => (
        Icons.wifi_off_rounded,
        'No internet connection — attendance will be saved on this device '
            'and synced automatically.',
      ),
      ConnectivityStatus.serverUnreachable => (
        Icons.cloud_off_rounded,
        "Can't reach the server — attendance will be saved on this device "
            'and synced automatically.',
      ),
      ConnectivityStatus.online => (null, null),
    };

    if (icon == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: KioskColors.warning.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(
            color: KioskColors.warning.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(icon, color: KioskColors.warning, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message!,
                style: TextStyle(
                  color: KioskColors.warning,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
