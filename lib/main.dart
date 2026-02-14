import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://gcevaajlekxtbupgptil.supabase.co',
    anonKey: 'sb_publishable_Od7jWhMwrJ5vn-1CUOjFsw_BFrfFiyo',
  );

  runApp(const FaceAttendanceApp());
}
