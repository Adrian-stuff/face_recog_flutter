import 'package:flutter/material.dart';

import '../services/network_service.dart';
import '../services/provisioning_service.dart';

/// Message to show the admin for each way a WiFi scan can fail to run.
/// Mirrors the one in settings_screen.dart — kept separate since that one
/// is private to its file.
String _wifiScanFailureMessage(WifiScanFailure reason) {
  switch (reason) {
    case WifiScanFailure.notSupported:
      return "This device can't scan for nearby networks — type the name manually.";
    case WifiScanFailure.permissionOrLocationRequired:
      return 'Location permission and services must be enabled to scan for nearby WiFi networks.';
  }
}

/// Shown once, right after a device pairs, before it's allowed into the
/// normal kiosk screen. Captures the office WiFi network and GPS reading and
/// sends them to the dashboard — an admin setting up the corresponding
/// office location then has real values to copy instead of typing a BSSID
/// or coordinate by hand.
///
/// Nothing here is required to keep working: GPS and WiFi enforcement are
/// both already optional at the NetworkGuard layer when unconfigured, and
/// this screen's own "Skip" exists for exactly that reason — a device that
/// can't detect anything (denied permissions, unsupported platform) must
/// still be able to reach the kiosk.
class NetworkSetupScreen extends StatefulWidget {
  const NetworkSetupScreen({super.key});

  @override
  State<NetworkSetupScreen> createState() => _NetworkSetupScreenState();
}

class _NetworkSetupScreenState extends State<NetworkSetupScreen> {
  final _networkService = NetworkService();
  final _ssidController = TextEditingController();

  bool _isScanningWifi = true;
  List<WifiNetworkResult> _networks = [];
  String? _wifiError;

  // Captured together at selection time and never mutated independently, so
  // there's no risk of the BSSID silently drifting out of sync with
  // whatever SSID text is currently on screen — see _bssidForSync.
  String? _selectedBssid;
  String? _selectedForSsid;

  bool _isDetectingLocation = true;
  GeoReading? _geo;
  bool _locationDenied = false;

  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _scanWifi();
    _detectLocation();
  }

  @override
  void dispose() {
    _ssidController.dispose();
    super.dispose();
  }

  Future<void> _scanWifi() async {
    setState(() {
      _isScanningWifi = true;
      _wifiError = null;
    });

    List<WifiNetworkResult> networks = [];
    String? error;
    try {
      networks = await _networkService.scanNearbyNetworks();
    } on WifiScanException catch (e) {
      error = _wifiScanFailureMessage(e.reason);
    } catch (e) {
      error = "Couldn't scan for networks: $e";
    }

    if (!mounted) return;

    // Pre-select whichever network the phone happens to be connected to
    // right now — very likely the office WiFi, and saves a tap in the
    // common case. The admin can still pick a different one from the list.
    final currentSsid = await _networkService.getCurrentSSID();

    if (!mounted) return;
    setState(() {
      _networks = networks;
      _wifiError = error;
      _isScanningWifi = false;

      if (currentSsid != null) {
        final match = networks.where((n) => n.ssid == currentSsid);
        if (match.isNotEmpty) {
          _ssidController.text = match.first.ssid;
          _selectedBssid = match.first.bssid;
          _selectedForSsid = match.first.ssid;
        } else {
          // Connected to something the scan didn't pick up (e.g. a scan
          // that finished before this network's beacon was seen). Still
          // worth prefilling the name even without a matched BSSID.
          _ssidController.text = currentSsid;
        }
      }
    });
  }

  Future<void> _detectLocation() async {
    setState(() {
      _isDetectingLocation = true;
      _locationDenied = false;
    });

    final geo = await _networkService.getCurrentGeoReading();

    if (!mounted) return;
    setState(() {
      _geo = geo;
      _locationDenied = geo == null;
      _isDetectingLocation = false;
    });
  }

  void _selectNetwork(WifiNetworkResult network) {
    setState(() {
      _ssidController.text = network.ssid;
      _selectedBssid = network.bssid;
      _selectedForSsid = network.ssid;
    });
  }

  /// The BSSID to send, or null if the admin has edited the SSID field
  /// since it was captured — a BSSID only means anything paired with the
  /// exact network it belongs to.
  String? get _bssidForSync {
    if (_selectedBssid == null) return null;
    return _selectedForSsid == _ssidController.text.trim() ? _selectedBssid : null;
  }

  Future<void> _sync() async {
    final ssid = _ssidController.text.trim();
    if (ssid.isEmpty && _geo == null) {
      await _finish();
      return;
    }

    setState(() => _isSyncing = true);

    final ok = await ProvisioningService.instance.reportDetectedNetwork(
      wifiSsid: ssid.isEmpty ? null : ssid,
      wifiBssid: ssid.isEmpty ? null : _bssidForSync,
      lat: _geo?.latitude,
      lng: _geo?.longitude,
    );

    if (!mounted) return;
    setState(() => _isSyncing = false);

    if (ok) {
      await _finish();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't reach the dashboard. Check the connection and try again, or skip for now."),
        ),
      );
    }
  }

  Future<void> _finish() async {
    await ProvisioningService.instance.finishNetworkSetup();
    // No navigation needed — app.dart's ValueListenableBuilder swaps to the
    // kiosk screen the moment ProvisioningService.state flips to ready.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Set up this device')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              "Detect this kiosk's WiFi and location so an admin can set up "
              'its office location from the dashboard without typing '
              'coordinates by hand.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            _SectionCard(
              icon: Icons.wifi,
              title: 'WiFi network',
              child: _buildWifiSection(theme),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              icon: Icons.location_on,
              title: 'Location (GPS)',
              child: _buildLocationSection(theme),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _isSyncing ? null : _sync,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _isSyncing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sync to Dashboard'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _isSyncing ? null : _finish,
              child: const Text("Skip — I'll configure this from the dashboard"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWifiSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ssidController,
          decoration: const InputDecoration(
            labelText: 'Network name (SSID)',
            border: OutlineInputBorder(),
            helperText: 'Auto-filled from the network this device is on — edit if that\'s wrong',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 10),
        if (_isScanningWifi)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Scanning for nearby networks…'),
              ],
            ),
          )
        else if (_wifiError != null)
          Text(_wifiError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 13))
        else if (_networks.isEmpty)
          const Text('No nearby networks found. Type the name manually.', style: TextStyle(fontSize: 13))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _networks.take(8).map((n) {
              final selected = n.ssid == _selectedForSsid && n.bssid == _selectedBssid;
              return ChoiceChip(
                label: Text(n.ssid),
                selected: selected,
                onSelected: (_) => _selectNetwork(n),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildLocationSection(ThemeData theme) {
    if (_isDetectingLocation) {
      return const Row(
        children: [
          SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('Detecting location…'),
        ],
      );
    }

    if (_geo != null) {
      return Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Captured: ${_geo!.latitude.toStringAsFixed(6)}, ${_geo!.longitude.toStringAsFixed(6)}',
            ),
          ),
          TextButton(onPressed: _detectLocation, child: const Text('Retry')),
        ],
      );
    }

    return Row(
      children: [
        Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _locationDenied
                ? 'Location unavailable — check permission and that GPS is enabled.'
                : "Couldn't detect location.",
            style: const TextStyle(fontSize: 13),
          ),
        ),
        TextButton(onPressed: _detectLocation, child: const Text('Retry')),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _SectionCard({required this.icon, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
