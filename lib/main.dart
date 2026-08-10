import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/app_config.dart';
import 'services/background_sync_service.dart';
import 'services/device_reporting_service.dart';
import 'services/provisioning_service.dart';
import 'services/update_service.dart';
import 'app.dart';

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Uncaught framework errors (widget build/layout/paint) — report to the
      // dashboard in addition to the default red-screen/console behavior.
      final defaultOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        defaultOnError?.call(details);
        DeviceReportingService.instance.reportError(
          'Uncaught Flutter error: ${details.exceptionAsString()}',
          context: details.stack?.toString(),
        );
      };

      // Uncaught errors outside the Flutter framework (async gaps, isolates).
      PlatformDispatcher.instance.onError = (error, stack) {
        DeviceReportingService.instance.reportError(
          'Uncaught platform error: $error',
          context: stack.toString(),
        );
        return true;
      };

      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
      );

      // Must complete before the first screen builds: every authenticated
      // request reads its key from here, and the app decides between the
      // setup screen and the kiosk based on whether this device is bound to
      // a company yet.
      await ProvisioningService.instance.load();

      // So attendance/scan-event uploads still eventually reach the server
      // if the employee closes the app entirely — the foreground sync loop
      // in SupabaseService only runs while the app process is alive. Safe to
      // call on every cold start: registerPeriodicTask with keep policy
      // below is a no-op if the OS already has this task scheduled.
      BackgroundSyncService.initialize();

      // Trigger background Shorebird update check (fire & forget).
      // If an update is available it will be downloaded silently;
      // the app.dart widget will show a restart banner.
      UpdateService.instance.checkAndUpdate().then((updated) {
        if (updated) {
          debugPrint('Shorebird: patch downloaded — will apply on next restart');
        }
      });

      runApp(const FaceAttendanceApp());
    },
    (error, stack) {
      // Errors escaping the zone entirely (e.g. thrown from a callback with
      // no surrounding try/catch and outside Flutter's own error hooks).
      DeviceReportingService.instance.reportError(
        'Uncaught zone error: $error',
        context: stack.toString(),
      );
    },
  );
}
