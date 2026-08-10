import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../config/app_config.dart';
import 'device_reporting_service.dart';
import 'provisioning_service.dart';
import 'supabase_service.dart';

/// True background sync — reaches the server even if the employee has closed
/// the app entirely, not just backgrounded it.
///
/// SupabaseService.startBackgroundSync's Timer only runs while the app
/// process is alive. That's fine for a kiosk tablet mounted on a wall and
/// never closed, but this app also runs as personal-device self-service
/// time-in/out (see registration_screen.dart), and an employee closing that
/// app afterwards is completely normal — anything they recorded offline
/// would otherwise just sit on the device until they happened to reopen it.
///
/// Uses WorkManager on Android and BGTaskScheduler on iOS (same plugin API,
/// different OS underneath). Both are OS-scheduled, not app-scheduled: the
/// app requests a periodic task, but the OS decides exactly when to actually
/// run it based on battery state, idle time, etc. Android's WorkManager
/// enforces a 15-minute floor on periodic work — that can't be tightened,
/// which is exactly why the foreground 30-second tick in SupabaseService
/// exists as its own, much tighter loop rather than relying on this. iOS's
/// BGTaskScheduler is considerably less predictable than even that — the OS
/// can defer a task for hours, or skip it entirely if the app isn't opened
/// often — so treat this as a best-effort backstop, not a guarantee,
/// especially on iOS.
class BackgroundSyncService {
  static const _uniqueName = 'mobile_app.background_sync.periodic';
  static const _taskName = 'mobile_app.background_sync';

  static Future<void> initialize() async {
    try {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerPeriodicTask(
        _uniqueName,
        _taskName,
        // Android silently clamps anything shorter than this anyway; naming
        // the real floor here avoids implying a tighter guarantee than the
        // OS actually gives.
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        // Re-registering on every cold start (see main.dart) must not reset
        // an already-scheduled task's timer.
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('BackgroundSyncService: failed to schedule background sync: $e');
    }
  }
}

/// Entry point the OS calls in a separate headless Dart isolate it spawns
/// just for this task — a fresh VM with none of the foreground app's state,
/// which is why this redoes the same startup steps main.dart does
/// (Supabase.initialize, ProvisioningService.load) before touching anything
/// that depends on them.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
      );

      await ProvisioningService.instance.load();
      if (ProvisioningService.instance.apiKey.isEmpty) {
        // Never paired and no build-time key either — nothing to sync yet.
        return true;
      }

      final supabaseService = SupabaseService();

      // A real reachability check, not just "a radio is associated" — see
      // the comment on SupabaseService.startBackgroundSync for why that
      // distinction matters. No sense attempting uploads the OS is only
      // going to report as failed anyway.
      if (!await supabaseService.pingServer()) {
        return true;
      }

      // Sequenced, not parallel — syncScanEvents() links each scan's
      // evidence row to its attendance log by client_event_id, which only
      // works once the log actually exists server-side.
      await supabaseService.syncLogs();
      await supabaseService.syncEncodings();
      await supabaseService.syncScanEvents();
      await DeviceReportingService.instance.syncPendingErrorReports();
    } catch (e) {
      debugPrint('BackgroundSyncService: background task failed: $e');
    }
    // Always true: WorkManager's retry policy is for the task itself
    // (crashed, timed out), not for individual records a sync attempt
    // couldn't send — those already have their own local retry/backoff
    // handled by SupabaseService, and returning false here would just make
    // WorkManager hammer the whole task again shortly on top of that.
    return true;
  });
}
