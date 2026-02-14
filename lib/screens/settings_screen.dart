import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../config/app_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ssidController = TextEditingController();
  final _settingsService = SettingsService();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
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
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                ],
              ),
            ),
    );
  }
}
