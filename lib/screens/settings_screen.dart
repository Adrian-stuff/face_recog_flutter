import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../services/network_service.dart';
import '../config/app_config.dart';

/// Message to show the admin for each way a WiFi scan can fail to run.
String _wifiScanFailureMessage(WifiScanFailure reason) {
  switch (reason) {
    case WifiScanFailure.notSupported:
      return "Scanning for nearby networks isn't supported on this device — "
          'please type the network name manually.';
    case WifiScanFailure.permissionOrLocationRequired:
      return 'Location permission and services must be enabled to scan for '
          'nearby WiFi networks.';
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ssidController = TextEditingController();
  final _bssidController = TextEditingController();
  final _latController = TextEditingController();
  final _lngController = TextEditingController();
  final _radiusController = TextEditingController();
  final _settingsService = SettingsService();
  final _networkService = NetworkService();
  final _updateService = UpdateService.instance;
  bool _isLoading = true;
  bool _isDetectingBSSID = false;
  bool _isDetectingLocation = false;
  bool _isScanningWifi = false;

  // Update state
  int? _patchNumber;
  bool _isCheckingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadPatchInfo();
  }

  Future<void> _loadSettings() async {
    final ssid = await _settingsService.getWifiSSID();
    final bssid = await _settingsService.getWifiBSSID();
    final geofence = await _settingsService.getGeofence();
    if (mounted) {
      setState(() {
        _ssidController.text = ssid;
        _bssidController.text = bssid;
        _latController.text = geofence?.latitude.toString() ?? '';
        _lngController.text = geofence?.longitude.toString() ?? '';
        _radiusController.text =
            (geofence?.radiusMeters ??
                    SettingsService.defaultGeofenceRadiusMeters)
                .toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _detectCurrentLocation() async {
    setState(() => _isDetectingLocation = true);
    final geo = await _networkService.getCurrentGeoReading();
    if (mounted) {
      setState(() => _isDetectingLocation = false);
      if (geo != null) {
        setState(() {
          _latController.text = geo.latitude.toString();
          _lngController.text = geo.longitude.toString();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't read this device's location."),
          ),
        );
      }
    }
  }

  Future<void> _detectCurrentBSSID() async {
    setState(() => _isDetectingBSSID = true);
    final bssid = await _networkService.getCurrentBSSID();
    if (mounted) {
      setState(() => _isDetectingBSSID = false);
      if (bssid != null) {
        setState(() => _bssidController.text = bssid);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't read this device's access point address."),
          ),
        );
      }
    }
  }

  Future<void> _pickNearbyWifi() async {
    setState(() => _isScanningWifi = true);
    List<String>? networks;
    WifiScanFailure? failure;
    try {
      networks = await _networkService.scanNearbyNetworkNames();
    } on WifiScanException catch (e) {
      failure = e.reason;
    }

    if (!mounted) return;
    setState(() => _isScanningWifi = false);

    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_wifiScanFailureMessage(failure))));
      return;
    }

    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _WifiPickerSheet(networks: networks!),
    );

    if (selected != null && mounted) {
      setState(() => _ssidController.text = selected);
    }
  }

  Future<void> _loadPatchInfo() async {
    final patchNumber = await _updateService.getCurrentPatchNumber();
    if (mounted) {
      setState(() => _patchNumber = patchNumber);
    }
  }

  Future<void> _saveSettings() async {
    await _settingsService.setWifiSSID(_ssidController.text.trim());
    await _settingsService.setWifiBSSID(_bssidController.text.trim());

    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (lat == null || lng == null) {
      await _settingsService.resetGeofence();
    } else {
      final radius =
          double.tryParse(_radiusController.text.trim()) ??
          SettingsService.defaultGeofenceRadiusMeters;
      await _settingsService.setGeofence(lat, lng, radius);
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> _resetToDefault() async {
    await _settingsService.resetWifiSSID();
    await _settingsService.resetWifiBSSID();
    await _settingsService.resetGeofence();
    await _loadSettings();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Reset to default')));
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingUpdate = true);

    final updated = await _updateService.checkAndUpdate();

    if (mounted) {
      setState(() => _isCheckingUpdate = false);
      await _loadPatchInfo();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            updated
                ? 'Update downloaded! Restart the app to apply.'
                : 'You are up to date.',
          ),
          backgroundColor: updated ? Colors.green : Colors.blue,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _bssidController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Network Configuration ──
                  const Text(
                    "Network Configuration",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _ssidController,
                    decoration: InputDecoration(
                      labelText: "Target WiFi SSID",
                      border: const OutlineInputBorder(),
                      helperText:
                          "The WiFi network name required for attendance.",
                      suffixIcon: _isScanningWifi
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.wifi_tethering),
                              tooltip: "Select from networks in range",
                              onPressed: _pickNearbyWifi,
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Default: ${AppConfig.officeWifiSSID}",
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _bssidController,
                    decoration: InputDecoration(
                      labelText: "Access Point BSSID (optional)",
                      border: const OutlineInputBorder(),
                      helperText:
                          "Locks attendance to this specific router, so a "
                          "renamed rogue network can't pass as the office WiFi. "
                          "Leave blank to skip this check.",
                      suffixIcon: _isDetectingBSSID
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.wifi_find),
                              tooltip: "Use this device's current network",
                              onPressed: _detectCurrentBSSID,
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "GPS Geofence (optional)",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "A second, independent check on top of WiFi. Leave "
                    "latitude/longitude blank to skip it.",
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _latController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: "Office Latitude",
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _lngController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: "Office Longitude",
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _radiusController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: "Allowed Radius (meters)",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isDetectingLocation
                          ? null
                          : _detectCurrentLocation,
                      icon: _isDetectingLocation
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                      label: const Text("Use This Device's Current Location"),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: _resetToDefault,
                        child: const Text("Reset Default"),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _saveSettings,
                          child: const Text("Save Changes"),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 16),

                  // ── App Updates (Shorebird) ──
                  const Text(
                    "App Updates",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.system_update_alt,
                                color: Colors.blue.shade700,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "Over-the-Air Updates",
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _updateService.isAvailable
                                          ? _patchNumber != null
                                                ? "Patch #$_patchNumber installed"
                                                : "No patches installed"
                                          : "Not available (debug build)",
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed:
                                  _updateService.isAvailable &&
                                      !_isCheckingUpdate
                                  ? _checkForUpdates
                                  : null,
                              icon: _isCheckingUpdate
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.refresh),
                              label: Text(
                                _isCheckingUpdate
                                    ? "Checking..."
                                    : "Check for Updates",
                              ),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Bottom sheet listing nearby WiFi networks found by a scan; tapping one
/// returns its SSID via [Navigator.pop].
class _WifiPickerSheet extends StatelessWidget {
  const _WifiPickerSheet({required this.networks});

  final List<String> networks;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text(
                "Networks in range",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            if (networks.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Text("No networks found nearby."),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: networks.length,
                  itemBuilder: (context, index) {
                    final ssid = networks[index];
                    return ListTile(
                      leading: const Icon(Icons.wifi),
                      title: Text(ssid),
                      onTap: () => Navigator.pop(context, ssid),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
