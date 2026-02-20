import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'services/update_service.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
}
