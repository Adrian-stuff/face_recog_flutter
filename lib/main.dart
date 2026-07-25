import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'services/device_reporting_service.dart';
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
        url: 'https://gcevaajlekxtbupgptil.supabase.co',
        anonKey: 'sb_publishable_Od7jWhMwrJ5vn-1CUOjFsw_BFrfFiyo',
      );

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
