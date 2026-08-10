import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/network_service.dart';
import '../services/settings_service.dart';
import '../widgets/admin_login_dialog.dart';
import '../screens/registration_screen.dart';

/// Decides whether the kiosk may be used, given which signals an admin has
/// actually enforced and whether each one currently passes.
///
/// Pulled out as a pure function (no widget/service dependencies) so the
/// rule is pinned down with a test: WiFi, when enforced, is checked first
/// and decides on its own — GPS is never a way to override a WiFi mismatch.
/// GPS is a second, independent signal layered on top, only reached once
/// WiFi (when enforced) has already passed. With neither enforced, nothing
/// blocks the kiosk.
///
/// Important distinction this check relies on: "connected to the office
/// WiFi" and "that WiFi has working internet" are different questions. The
/// WiFi check itself (see NetworkService.getCurrentSSID/getCurrentBSSID)
/// reads the radio's currently-associated network directly — no HTTP
/// request involved — so a device on the right SSID passes this check
/// whether or not that network's uplink is actually working. The kiosk
/// stays usable through a WiFi/internet outage as long as it's still
/// associated with the configured office network and already has a synced
/// local roster; it just can't reach the server to sync anything new until
/// connectivity actually returns.
bool computeNetworkGuardAllowed({
  required bool wifiEnforced,
  required bool wifiOk,
  required bool geoEnforced,
  required bool geoOk,
}) {
  if (wifiEnforced && !wifiOk) return false;
  if (geoEnforced && !geoOk) return false;
  return true;
}

/// Whether the device's live WiFi state satisfies whatever SSID/BSSID an
/// admin configured for this location. Pulled out as a pure function for the
/// same reason as [computeNetworkGuardAllowed]: the BSSID half of this has a
/// non-obvious rule worth pinning down with a test.
///
/// A null [currentBSSID] is treated as "can't verify," not "mismatch." BSSID
/// exists as defense-in-depth against a rogue AP broadcasting the office's
/// SSID — but reading it at all requires a special Apple entitlement Apple
/// rarely grants third-party apps, so [currentBSSID] is null on effectively
/// every iOS device (see NetworkService.getCurrentBSSID). Comparing that
/// null directly against a configured BSSID would fail every time, so the
/// instant an admin adds a BSSID to a location, every iOS kiosk sitting on
/// the exact right SSID would be locked out anyway. SSID stays the
/// authoritative signal; BSSID only tightens the check on devices that can
/// actually report it.
bool computeWifiOk({
  required String? currentSSID,
  required String requiredSSID,
  required String? currentBSSID,
  required String requiredBSSID,
}) {
  if (currentSSID == null) return requiredSSID.isEmpty;
  final ssidOk = requiredSSID.isEmpty || currentSSID == requiredSSID;
  final bssidOk = requiredBSSID.isEmpty ||
      currentBSSID == null ||
      currentBSSID == requiredBSSID;
  return ssidOk && bssidOk;
}

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
  String? _currentBSSID;
  String? _locationFailureReason;

  // Set once both signals have been evaluated, so the failure screen can
  // explain whichever ones are actually enforced instead of only ever
  // mentioning WiFi.
  bool _wifiEnforced = false;
  bool _geoEnforced = false;
  bool _wifiFailed = false;

  StreamSubscription? _subscription;

  // _checkNetwork() is triggered from 5 independent places (initState, the
  // connectivity-change listener below, app-resume, the "Retry Connection"
  // button, and re-checking after admin settings) with no sequencing between
  // them. Under flapping WiFi, two calls can be in flight at once, and
  // without this an older one finishing after a newer one would overwrite
  // correct state with stale data. Each call captures its own generation at
  // the top; a setState only applies if that's still the latest.
  int _checkGeneration = 0;

  bool _isStale(int generation) =>
      !mounted || generation != _checkGeneration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNetwork();
    _subscription = _networkService.onConnectivityChanged.listen((
      List<ConnectivityResult> result,
    ) {
      // Connectivity events fire before the OS finishes associating with the
      // new network — reading the SSID immediately after the event would race
      // the OS and return a stale or null value, making the guard incorrectly
      // show "Incorrect WiFi Network" on a valid reconnect. The short delay
      // lets the association settle first without noticeably delaying the UI.
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) _checkNetwork();
      });
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
    final generation = ++_checkGeneration;

    if (_isStale(generation)) return;
    setState(() => _isLoading = true);
    _locationFailureReason = null;

    String? ssid = await _networkService.getCurrentSSID();
    String requiredSSID = await _settingsService.getWifiSSID();
    String? bssid = await _networkService.getCurrentBSSID();
    String requiredBSSID = await _settingsService.getWifiBSSID();

    if (_isStale(generation)) return;

    _wifiEnforced = requiredSSID.isNotEmpty;
    String? cleanedSSID;
    if (ssid != null) {
      cleanedSSID = _networkService.cleanSSID(ssid);
      _currentSSID = cleanedSSID;
      _currentBSSID = bssid ?? 'Unavailable on this device';
    } else {
      _currentSSID = 'Unknown / Not Connected';
      _currentBSSID = null;
    }

    // Same convention throughout: an empty requiredSSID/requiredBSSID means
    // "not enforced yet" rather than "must match empty string". A brand new
    // device — paired but not yet assigned to an office location with WiFi
    // configured — must be usable, not locked out by a check nobody has set
    // up. Once an admin does configure a location, this starts enforcing on
    // the device's next sync.
    final wifiOk = computeWifiOk(
      currentSSID: cleanedSSID,
      requiredSSID: requiredSSID,
      currentBSSID: bssid,
      requiredBSSID: requiredBSSID,
    );
    _wifiFailed = !wifiOk;

    if (_wifiEnforced && !wifiOk) {
      // WiFi is the admin's configured signal for this device and it
      // failed — blocked, full stop. GPS is not consulted: it's not a way
      // to override a WiFi mismatch (that would let anyone bypass WiFi
      // enforcement just by disabling GPS accuracy or spoofing location),
      // and skipping the GPS lock here means an operator on the wrong
      // network sees the failure immediately instead of waiting on a GPS
      // fix that was never going to change the outcome.
      _geoEnforced = false;
      _locationFailureReason = null;
      if (_isStale(generation)) return;
      setState(() {
        _isAllowed = false;
        _isLoading = false;
      });
      return;
    }

    // GPS geofence is a second, independent signal — only enforced once an
    // admin has captured office coordinates, and only reached once WiFi
    // (when enforced) has already passed.
    final geofence = await _settingsService.getGeofence();
    _geoEnforced = geofence != null;
    bool geoOk = true;
    if (geofence != null) {
      final geo = await _networkService.getCurrentGeoReading();
      if (geo == null) {
        _locationFailureReason = 'Unable to verify device location';
        geoOk = false;
      } else if (geo.isMocked) {
        _locationFailureReason = 'Mock/fake location detected on this device';
        geoOk = false;
      } else {
        final distance = _networkService.distanceMeters(
          geo.latitude,
          geo.longitude,
          geofence.latitude,
          geofence.longitude,
        );
        if (distance > geofence.radiusMeters) {
          _locationFailureReason =
              'Outside office location (${distance.round()}m away, '
              'allowed ${geofence.radiusMeters.round()}m)';
          geoOk = false;
        }
      }
    }

    final allowed = computeNetworkGuardAllowed(
      wifiEnforced: _wifiEnforced,
      wifiOk: wifiOk,
      geoEnforced: _geoEnforced,
      geoOk: geoOk,
    );

    if (_isStale(generation)) return;
    setState(() {
      _isAllowed = allowed;
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
      // WiFi, when enforced, is checked first and short-circuits before GPS
      // is ever evaluated (see computeNetworkGuardAllowed) — so these two
      // can never both be the reason at once. Whichever is set here is the
      // one and only culprit.
      final wifiIsCulprit = _wifiEnforced && _wifiFailed;
      final geoIsCulprit = _geoEnforced && _locationFailureReason != null;
      final title = geoIsCulprit ? 'Location Check Failed' : 'Incorrect WiFi Network';

      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                geoIsCulprit ? Icons.location_off : Icons.wifi_off,
                size: 64,
                color: Colors.red,
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (wifiIsCulprit)
                const Text(
                  'This app can only be used when connected to the office WiFi.',
                  textAlign: TextAlign.center,
                ),
              if (geoIsCulprit)
                Text(_locationFailureReason!, textAlign: TextAlign.center),

              if (wifiIsCulprit) ...[
                const SizedBox(height: 8),
                Text(
                  'Current: ${_currentSSID ?? "None"}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              ],
              if (wifiIsCulprit && _currentBSSID != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Access point: $_currentBSSID',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
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
