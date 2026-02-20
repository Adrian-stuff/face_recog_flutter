import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../config/app_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ssidController = TextEditingController();
  final _settingsService = SettingsService();
  final _updateService = UpdateService.instance;
  bool _isLoading = true;

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
    if (mounted) {
      setState(() {
        _ssidController.text = ssid;
        _isLoading = false;
      });
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
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> _resetToDefault() async {
    await _settingsService.resetWifiSSID();
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
                    decoration: const InputDecoration(
                      labelText: "Target WiFi SSID",
                      border: OutlineInputBorder(),
                      helperText:
                          "The WiFi network name required for attendance.",
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Default: ${AppConfig.officeWifiSSID}",
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
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
