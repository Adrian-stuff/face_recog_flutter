import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_config.dart';
import 'update_service.dart';

/// Why this device is or isn't allowed to operate right now.
enum ProvisioningState {
  /// Never paired and no build-time key compiled in — needs admin setup.
  unprovisioned,

  /// Just paired via code and hasn't reported its WiFi/GPS yet. Only ever
  /// entered right after [ProvisioningService.pair] — a device running on
  /// the legacy build-time key skips straight to [ready], since it was
  /// never "paired" in the sense this step is about.
  needsNetworkSetup,

  /// Paired (or running on a legacy build-time key) and free to sync.
  ready,

  /// The server reports this key now belongs to a different company than the
  /// one we paired with. Refuse to run rather than serve another tenant's
  /// roster on this hardware.
  companyMismatch,
}

class PairingResult {
  final bool success;
  final String? error;
  final String? companyName;

  const PairingResult._({required this.success, this.error, this.companyName});

  factory PairingResult.ok(String companyName) =>
      PairingResult._(success: true, companyName: companyName);
  factory PairingResult.failure(String error) =>
      PairingResult._(success: false, error: error);
}

/// Binds this installation to exactly one company.
///
/// Previously the credential was compiled in via `--dart-define MOBILE_API_KEY`,
/// which meant a separate build per customer and no way for the app to notice
/// it had been re-pointed at a different tenant. Now an admin generates a
/// short-lived pairing code in the dashboard, the device trades it for its own
/// key, and the company it belongs to is pinned locally and re-checked on
/// every ping.
class ProvisioningService {
  ProvisioningService._({FlutterSecureStorage? storage, http.Client? client})
    : _storage = storage ?? const FlutterSecureStorage(),
      _client = client ?? http.Client();

  static final ProvisioningService instance = ProvisioningService._();

  @visibleForTesting
  factory ProvisioningService.forTesting({
    required FlutterSecureStorage storage,
    required http.Client client,
  }) => ProvisioningService._(storage: storage, client: client);

  static const _keyApiKey = 'kiosk_api_key';
  static const _keyCompanyId = 'kiosk_company_id';
  static const _keyCompanyName = 'kiosk_company_name';
  static const _keyDeviceId = 'kiosk_device_id';
  static const _keyDeviceLabel = 'kiosk_device_label';
  static const _keyLocationId = 'kiosk_location_id';
  static const _keyPairedAt = 'kiosk_paired_at';
  static const _keyNetworkSetupDone = 'kiosk_network_setup_done';

  // Android's EncryptedSharedPreferences, so the key survives app restarts
  // but not an uninstall — a wiped device should have to be re-paired.
  static const _androidOptions = AndroidOptions(encryptedSharedPreferences: true);
  static const _requestTimeout = Duration(seconds: 15);

  final FlutterSecureStorage _storage;
  final http.Client _client;

  String? _apiKey;
  int? _companyId;
  String? _companyName;
  int? _deviceId;
  String? _deviceLabel;
  bool _networkSetupDone = false;
  bool _loaded = false;

  /// Surfaced to the UI so screens can react without polling.
  final ValueNotifier<ProvisioningState> state =
      ValueNotifier<ProvisioningState>(ProvisioningState.unprovisioned);
  final ValueNotifier<String?> companyName = ValueNotifier<String?>(null);

  /// The mismatch we detected, kept for the lock screen's explanation.
  String? mismatchDetail;

  int? get companyId => _companyId;

  /// The server-assigned kiosk_devices.id for this physical device, once
  /// paired. DeviceReportingService uses this (with [deviceLabel]) as the
  /// identity it tags error/sync-health reports with, instead of a
  /// self-generated random id — so a device showing up in the dashboard's
  /// Mobile App Health list is the same row an admin sees in Kiosk
  /// Configuration, not two disconnected identities for one physical phone.
  int? get deviceId => _deviceId;

  /// The label an admin gave this device (or its OS/version string if none
  /// was set) — "Front Desk Tablet" rather than an auto-generated
  /// "android-a3f9c1".
  String? get deviceLabel => _deviceLabel;

  /// The key to authenticate with, preferring the paired one.
  ///
  /// Falls back to the compiled-in key so devices built before pairing
  /// existed keep working; they resolve server-side through the legacy
  /// shared-key path until an admin re-pairs them.
  String get apiKey {
    if (_apiKey != null && _apiKey!.isNotEmpty) return _apiKey!;
    return AppConfig.mobileApiKey;
  }

  bool get isPaired => _apiKey != null && _apiKey!.isNotEmpty;

  /// True when the app may talk to the server and record attendance.
  bool get canOperate =>
      state.value == ProvisioningState.ready && apiKey.isNotEmpty;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final results = await Future.wait([
        _storage.read(key: _keyApiKey, aOptions: _androidOptions),
        _storage.read(key: _keyCompanyId, aOptions: _androidOptions),
        _storage.read(key: _keyCompanyName, aOptions: _androidOptions),
        _storage.read(key: _keyDeviceId, aOptions: _androidOptions),
        _storage.read(key: _keyNetworkSetupDone, aOptions: _androidOptions),
        _storage.read(key: _keyDeviceLabel, aOptions: _androidOptions),
      ]);
      _apiKey = results[0];
      _companyId = results[1] == null ? null : int.tryParse(results[1]!);
      _companyName = results[2];
      _deviceId = results[3] == null ? null : int.tryParse(results[3]!);
      _networkSetupDone = results[4] == 'true';
      _deviceLabel = results[5];
      companyName.value = _companyName;
    } catch (e) {
      // A device whose Keystore entry can't be read is not a device we should
      // silently fall back to the shared key on — leave it unprovisioned so
      // an admin re-pairs it deliberately.
      debugPrint('ProvisioningService: failed to read secure storage: $e');
    } finally {
      _loaded = true;
      state.value = _computeReadyState();
    }
  }

  // isPaired specifically (not just "has a key") — a legacy build-time key
  // was never paired through the code flow this step belongs to, so those
  // devices go straight to ready rather than being stopped for a setup step
  // that has nothing to do with how they were provisioned.
  ProvisioningState _computeReadyState() {
    if (apiKey.isEmpty) return ProvisioningState.unprovisioned;
    if (isPaired && !_networkSetupDone) return ProvisioningState.needsNetworkSetup;
    return ProvisioningState.ready;
  }

  /// Trades a one-time pairing code for this device's own key.
  Future<PairingResult> pair(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      return PairingResult.failure('Enter the pairing code from the dashboard.');
    }

    String label = Platform.operatingSystem;
    try {
      final info = await PackageInfo.fromPlatform();
      // The native build number alone can't tell two devices apart once
      // Shorebird is in the picture: two kiosks on the same build (e.g.
      // 1.2.0+67) can be running different OTA patches, which is exactly
      // the divergence a platform operator needs visible on this label.
      final patch = await UpdateService.instance.getCurrentPatchNumber();
      label = patch != null
          ? '${Platform.operatingSystem} ${info.version}+${info.buildNumber}-p$patch'
          : '${Platform.operatingSystem} ${info.version}+${info.buildNumber}';
    } catch (_) {
      // Label is cosmetic; pairing shouldn't fail because we couldn't read it.
    }

    try {
      final response = await _client
          .post(
            Uri.parse('${AppConfig.nextJsBaseUrl}/api/kiosk/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': trimmed, 'deviceLabel': label}),
          )
          .timeout(_requestTimeout);

      if (response.statusCode != 201) {
        String message = 'Pairing failed (HTTP ${response.statusCode}).';
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          if (body['error'] is String) message = body['error'] as String;
        } catch (_) {}
        return PairingResult.failure(message);
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final newKey = body['apiKey'] as String?;
      final newCompanyId = body['companyId'] as int?;
      final newCompanyName = body['companyName'] as String? ?? 'Unknown company';

      if (newKey == null || newCompanyId == null) {
        return PairingResult.failure('Server returned an incomplete pairing response.');
      }

      await _persist(
        apiKey: newKey,
        companyId: newCompanyId,
        companyName: newCompanyName,
        deviceId: body['deviceId'] as int?,
        deviceLabel: body['deviceLabel'] as String? ?? label,
        locationId: body['locationId'] as int?,
      );

      mismatchDetail = null;
      // Every (re)pair — including recovering from a company mismatch —
      // starts a fresh network-setup prompt. The device may physically be
      // somewhere new even if it isn't, so there's no case where carrying
      // over a stale "done" flag from a previous company is correct.
      _networkSetupDone = false;
      await _storage.delete(key: _keyNetworkSetupDone, aOptions: _androidOptions);
      state.value = ProvisioningState.needsNetworkSetup;
      return PairingResult.ok(newCompanyName);
    } on http.ClientException catch (e) {
      return PairingResult.failure('Could not reach the server: ${e.message}');
    } catch (e) {
      return PairingResult.failure('Pairing failed: $e');
    }
  }

  Future<void> _persist({
    required String apiKey,
    required int companyId,
    required String companyName,
    int? deviceId,
    String? deviceLabel,
    int? locationId,
  }) async {
    _apiKey = apiKey;
    _companyId = companyId;
    _companyName = companyName;
    _deviceId = deviceId;
    _deviceLabel = deviceLabel;
    this.companyName.value = companyName;

    await Future.wait([
      _storage.write(key: _keyApiKey, value: apiKey, aOptions: _androidOptions),
      _storage.write(
        key: _keyCompanyId,
        value: companyId.toString(),
        aOptions: _androidOptions,
      ),
      _storage.write(
        key: _keyCompanyName,
        value: companyName,
        aOptions: _androidOptions,
      ),
      _storage.write(
        key: _keyDeviceId,
        value: deviceId?.toString() ?? '',
        aOptions: _androidOptions,
      ),
      _storage.write(
        key: _keyDeviceLabel,
        value: deviceLabel ?? '',
        aOptions: _androidOptions,
      ),
      _storage.write(
        key: _keyLocationId,
        value: locationId?.toString() ?? '',
        aOptions: _androidOptions,
      ),
      _storage.write(
        key: _keyPairedAt,
        value: DateTime.now().toIso8601String(),
        aOptions: _androidOptions,
      ),
    ]);
  }

  /// Checks the company reported by a ping against the one we paired with.
  ///
  /// Returns true if the device may keep operating. A mismatch means this
  /// hardware was re-provisioned to another tenant while it still holds the
  /// previous tenant's cached roster and face vectors, so the caller must
  /// stop syncing and purge that cache.
  bool verifyCompany(int? serverCompanyId, String? serverCompanyName) {
    if (serverCompanyId == null) {
      // Pre-pairing servers don't send it. Nothing to verify against, and
      // failing closed here would brick every legacy device on upgrade.
      return true;
    }

    if (serverCompanyName != null && serverCompanyName.isNotEmpty) {
      companyName.value = serverCompanyName;
    }

    if (_companyId == null) {
      // First ping on a legacy build-time key: adopt what the server reports
      // so subsequent pings have something to compare against.
      _companyId = serverCompanyId;
      _companyName = serverCompanyName;
      _storage
          .write(
            key: _keyCompanyId,
            value: serverCompanyId.toString(),
            aOptions: _androidOptions,
          )
          .catchError((e) {
            debugPrint('ProvisioningService: failed to pin company id: $e');
          });
      return true;
    }

    if (_companyId != serverCompanyId) {
      mismatchDetail =
          'This device was set up for ${_companyName ?? 'company #$_companyId'} '
          '(id $_companyId) but the server now reports '
          '${serverCompanyName ?? 'company #$serverCompanyId'} (id $serverCompanyId).';
      state.value = ProvisioningState.companyMismatch;
      return false;
    }

    return true;
  }

  /// The server no longer recognizes this device's key at all — an admin
  /// deleted/revoked it, or (fleet-wide) the legacy shared key was disabled.
  /// Distinct from [verifyCompany]'s mismatch (the key still resolves, just
  /// to a different company): here it doesn't resolve to anything. Same
  /// recovery either way, so this reuses [ProvisioningState.companyMismatch]
  /// and the same re-pairing screen, just with wording that doesn't imply a
  /// company reassignment happened.
  void markRevoked() {
    mismatchDetail =
        "This device's pairing was revoked or removed by an administrator. "
        'Enter a new pairing code to continue.';
    state.value = ProvisioningState.companyMismatch;
  }

  /// Sends this device's currently detected WiFi network and/or GPS reading
  /// to the dashboard, so an admin setting up an office location has real
  /// values to copy instead of typing a BSSID or coordinate by hand.
  ///
  /// Both are optional — a report with just [lat]/[lng] is still useful on
  /// iOS, which can't scan nearby networks, and a report with just
  /// [wifiSsid] is still useful if GPS was denied. Returns false (without
  /// throwing) on any failure; [NetworkSetupScreen] treats that as "sync
  /// failed, offer to retry or skip" rather than blocking the kiosk.
  Future<bool> reportDetectedNetwork({
    String? wifiSsid,
    String? wifiBssid,
    double? lat,
    double? lng,
  }) async {
    if (wifiSsid == null && lat == null) return false;
    try {
      final response = await _client
          .post(
            Uri.parse('${AppConfig.nextJsBaseUrl}/api/kiosk/report-network'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
            },
            body: jsonEncode({
              if (wifiSsid != null) 'wifiSsid': wifiSsid,
              if (wifiBssid != null) 'wifiBssid': wifiBssid,
              if (lat != null) 'lat': lat,
              if (lng != null) 'lng': lng,
            }),
          )
          .timeout(_requestTimeout);
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('ProvisioningService: failed to report detected network: $e');
      return false;
    }
  }

  /// Marks the post-pairing network-setup step as done — whether it actually
  /// synced or the admin chose to skip it and configure the location from
  /// the dashboard instead. Either way there's nothing more to block the
  /// kiosk on, so this is the one method that advances to [ProvisioningState.ready].
  Future<void> finishNetworkSetup() async {
    _networkSetupDone = true;
    try {
      await _storage.write(key: _keyNetworkSetupDone, value: 'true', aOptions: _androidOptions);
    } catch (e) {
      // Non-fatal: worst case this prompts again next launch, which is
      // annoying but not unsafe — unlike leaving the kiosk stuck here.
      debugPrint('ProvisioningService: failed to persist network setup flag: $e');
    }
    state.value = ProvisioningState.ready;
  }

  /// Clears the binding so an admin can pair this device to another company.
  /// Callers are responsible for purging cached employee data first — this
  /// only drops the credential.
  Future<void> unpair() async {
    _apiKey = null;
    _companyId = null;
    _companyName = null;
    _deviceId = null;
    _deviceLabel = null;
    _networkSetupDone = false;
    companyName.value = null;
    mismatchDetail = null;

    try {
      await Future.wait([
        _storage.delete(key: _keyApiKey, aOptions: _androidOptions),
        _storage.delete(key: _keyCompanyId, aOptions: _androidOptions),
        _storage.delete(key: _keyCompanyName, aOptions: _androidOptions),
        _storage.delete(key: _keyDeviceId, aOptions: _androidOptions),
        _storage.delete(key: _keyDeviceLabel, aOptions: _androidOptions),
        _storage.delete(key: _keyLocationId, aOptions: _androidOptions),
        _storage.delete(key: _keyPairedAt, aOptions: _androidOptions),
        _storage.delete(key: _keyNetworkSetupDone, aOptions: _androidOptions),
      ]);
    } catch (e) {
      debugPrint('ProvisioningService: failed to clear secure storage: $e');
    }

    // A legacy build-time key has never gone through "pairing" in the sense
    // needsNetworkSetup is about, so unpairing it (dropping only the
    // never-set paired key) lands straight on ready, same as load()'s logic.
    state.value = _computeReadyState();
  }
}
