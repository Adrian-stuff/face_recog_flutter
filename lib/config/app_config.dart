class AppConfig {
  // Base URL for Next.js API.
  // Override for local testing: flutter run --dart-define-from-file=env.json
  // with NEXTJS_BASE_URL set in env.json (e.g. http://<your-lan-ip>:3000 —
  // not localhost, since that resolves to the phone itself, not your machine).
  static const String nextJsBaseUrl = String.fromEnvironment(
    'NEXTJS_BASE_URL',
    defaultValue: 'https://payroll-system-tau.vercel.app',
  );

  // API Key for Secure Communication.
  // Supplied at build time: flutter build <target> --dart-define-from-file=env.json
  // (env.json is gitignored; copy env.example.json and fill in the real key.)
  static const String mobileApiKey = String.fromEnvironment('MOBILE_API_KEY');

  // Shared with the background-sync isolate (see BackgroundSyncService),
  // which needs its own Supabase.initialize() call — it starts in a fresh
  // engine with none of main.dart's state. Kept here, not duplicated, so the
  // two initialize() calls can't drift apart.
  static const String supabaseUrl = 'https://gcevaajlekxtbupgptil.supabase.co';
  static const String supabaseAnonKey =
      'sb_publishable_Od7jWhMwrJ5vn-1CUOjFsw_BFrfFiyo';

  /// Employee avatar endpoint - constructs URL for getting employee avatar by ID
  static String getEmployeeAvatarUrl(int employeeId) {
    return '$nextJsBaseUrl/dashboard/employees/api/avatar?id=$employeeId';
  }
}
