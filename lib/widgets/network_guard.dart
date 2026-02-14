import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/network_service.dart';
import '../services/settings_service.dart';
import '../widgets/admin_login_dialog.dart';
import '../screens/registration_screen.dart';

class NetworkGuard extends StatefulWidget {
  final Widget child;

  const NetworkGuard({super.key, required this.child});

  @override
  State<NetworkGuard> createState() => _NetworkGuardState();
}

class _NetworkGuardState extends State<NetworkGuard>
    with WidgetsBindingObserver {
  final NetworkService _networkService = NetworkService();
  final SettingsService _settingsService = SettingsService();

  bool _isAllowed = false;
  bool _isLoading = true;
  String? _currentSSID;

  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNetwork();
    _subscription = _networkService.onConnectivityChanged.listen((
      List<ConnectivityResult> result,
    ) {
      _checkNetwork();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNetwork();
    }
  }

  Future<void> _checkNetwork() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    String? ssid = await _networkService.getCurrentSSID();
    String requiredSSID = await _settingsService.getWifiSSID();

    if (!mounted) return;

    if (ssid != null) {
      String cleanedSSID = _networkService.cleanSSID(ssid);
      _currentSSID = cleanedSSID;

      // Check if it matches config
      if (cleanedSSID == requiredSSID) {
        setState(() {
          _isAllowed = true;
          _isLoading = false;
        });
        return;
      }
    } else {
      _currentSSID = 'Unknown / Not Connected';
    }

    setState(() {
      _isAllowed = false;
      _isLoading = false;
    });
  }

  Future<void> _handleAdminLogin() async {
    // Show the reusable Admin Login Dialog
    final bool? success = await showDialog<bool>(
      context: context,
      builder: (_) => AdminLoginDialog(),
    );

    if (success == true && mounted) {
      // Proceed to Registration Screen (Admin Area)
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RegistrationScreen()),
      );
      // When back, re-check network (maybe SSID settings changed)
      _checkNetwork();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isAllowed) {
      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off, size: 64, color: Colors.red),
              const SizedBox(height: 24),
              const Text(
                'Incorrect WiFi Network',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'This app can only be used when connected to the office WiFi.',
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 8),
              Text(
                'Current: ${_currentSSID ?? "None"}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _checkNetwork,
                child: const Text('Retry Connection'),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _handleAdminLogin,
                icon: const Icon(Icons.admin_panel_settings),
                label: const Text('Admin Access (Update Settings)'),
              ),
            ],
          ),
        ),
      );
    }

    return widget.child;
  }
}
