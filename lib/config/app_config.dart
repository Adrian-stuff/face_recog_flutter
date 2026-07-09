class AppConfig {
  // TODO: Update this with your actual Office WiFi SSID
  static const String officeWifiSSID = 'PLDTHOMEFIBR5G6f700';

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

  /// Employee avatar endpoint - constructs URL for getting employee avatar by ID
  static String getEmployeeAvatarUrl(int employeeId) {
    return '$nextJsBaseUrl/api/dashboard/employees/avatar?id=$employeeId';
  }
}
