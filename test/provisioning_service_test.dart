import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobile_app/services/provisioning_service.dart';

/// In-memory stand-in for the platform channel FlutterSecureStorage talks
/// to, so tests never touch a real Keystore/Keychain. Implements only what
/// ProvisioningService actually calls.
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> _values = {};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _values[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    return _values[key];
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _values.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    return _values.containsKey(key);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async {
    return Map.of(_values);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _values.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStoragePlatform fakePlatform;
  const storage = FlutterSecureStorage();

  setUp(() {
    fakePlatform = _FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = fakePlatform;
  });

  ProvisioningService serviceWith(http.Client client) =>
      ProvisioningService.forTesting(storage: storage, client: client);

  group('load()', () {
    test('an untouched device is unprovisioned', () async {
      final service = serviceWith(MockClient((_) async => http.Response('', 500)));
      await service.load();
      expect(service.state.value, ProvisioningState.unprovisioned);
    });

    test('paired but never finished network setup resumes at needsNetworkSetup', () async {
      // Simulates the app being killed between pairing and completing the
      // setup screen, then relaunched — the prompt must not be skipped.
      await fakePlatform.write(key: 'kiosk_api_key', value: 'stored-key', options: {});
      await fakePlatform.write(key: 'kiosk_company_id', value: '1', options: {});

      final service = serviceWith(MockClient((_) async => http.Response('', 500)));
      await service.load();

      expect(service.state.value, ProvisioningState.needsNetworkSetup);
      expect(service.isPaired, isTrue);
    });

    test('paired and setup already completed goes straight to ready', () async {
      await fakePlatform.write(key: 'kiosk_api_key', value: 'stored-key', options: {});
      await fakePlatform.write(key: 'kiosk_company_id', value: '1', options: {});
      await fakePlatform.write(key: 'kiosk_network_setup_done', value: 'true', options: {});

      final service = serviceWith(MockClient((_) async => http.Response('', 500)));
      await service.load();

      expect(service.state.value, ProvisioningState.ready);
    });
  });

  group('pair()', () {
    test('success stores the credential and requires network setup before ready', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/kiosk/pair');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['code'], 'K7QM3XPA');
        return http.Response(
          jsonEncode({
            'apiKey': 'new-device-key',
            'deviceId': 14,
            'companyId': 2,
            'companyName': 'Acme Corp',
            'locationId': null,
          }),
          201,
        );
      });
      final service = serviceWith(client);
      await service.load();

      final result = await service.pair('K7QM3XPA');

      expect(result.success, isTrue);
      expect(result.companyName, 'Acme Corp');
      // Pairing alone must not be enough to reach ready — the whole point
      // of this state is that setup happens before the kiosk unlocks.
      expect(service.state.value, ProvisioningState.needsNetworkSetup);
      expect(service.apiKey, 'new-device-key');
      expect(service.companyId, 2);
    });

    test('a fresh pair resets a previously-completed network setup flag', () async {
      // Guards against a device that re-pairs to a different company (after
      // a mismatch, or a factory-reset kiosk reused elsewhere) silently
      // skipping setup because the old company's "done" flag was still set.
      await fakePlatform.write(key: 'kiosk_network_setup_done', value: 'true', options: {});

      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'apiKey': 'k', 'deviceId': 1, 'companyId': 1, 'companyName': 'Acme'}),
          201,
        ),
      );
      final service = serviceWith(client);
      await service.load();

      await service.pair('CODE1234');

      expect(service.state.value, ProvisioningState.needsNetworkSetup);
      expect(await fakePlatform.read(key: 'kiosk_network_setup_done', options: {}), isNull);
    });

    test('server rejection surfaces its error message and leaves state untouched', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'error': 'That pairing code is invalid, expired, or already used.'}), 400),
      );
      final service = serviceWith(client);
      await service.load();

      final result = await service.pair('BADCODE1');

      expect(result.success, isFalse);
      expect(result.error, 'That pairing code is invalid, expired, or already used.');
      expect(service.state.value, ProvisioningState.unprovisioned);
      expect(service.isPaired, isFalse);
    });

    test('an empty code is rejected without making a request', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 201);
      });
      final service = serviceWith(client);

      final result = await service.pair('   ');

      expect(result.success, isFalse);
      expect(called, isFalse);
    });
  });

  group('finishNetworkSetup()', () {
    test('persists completion and advances to ready', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'apiKey': 'k', 'deviceId': 1, 'companyId': 1, 'companyName': 'Acme'}),
          201,
        ),
      );
      final service = serviceWith(client);
      await service.load();
      await service.pair('CODE1234');
      expect(service.state.value, ProvisioningState.needsNetworkSetup);

      await service.finishNetworkSetup();

      expect(service.state.value, ProvisioningState.ready);
      expect(await fakePlatform.read(key: 'kiosk_network_setup_done', options: {}), 'true');
    });
  });

  group('reportDetectedNetwork()', () {
    test('sends only the fields that were actually detected, using the paired key', () async {
      // Seeded directly (bypassing pair()) so this test's mock client only
      // has to handle the one endpoint it's actually asserting on.
      await fakePlatform.write(key: 'kiosk_api_key', value: 'paired-device-key', options: {});

      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final service = serviceWith(client);
      await service.load();

      final ok = await service.reportDetectedNetwork(wifiSsid: 'OfficeWiFi', wifiBssid: 'aa:bb:cc:dd:ee:ff');

      expect(ok, isTrue);
      expect(captured!.url.path, '/api/kiosk/report-network');
      expect(captured!.headers['x-api-key'], 'paired-device-key');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['wifiSsid'], 'OfficeWiFi');
      expect(body['wifiBssid'], 'aa:bb:cc:dd:ee:ff');
      expect(body.containsKey('lat'), isFalse);
      expect(body.containsKey('lng'), isFalse);
    });

    test('reports GPS-only just as usefully as WiFi-only', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final service = serviceWith(client);
      await service.load();

      final ok = await service.reportDetectedNetwork(lat: 14.5995, lng: 120.9842);

      expect(ok, isTrue);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.containsKey('wifiSsid'), isFalse);
      expect(body['lat'], 14.5995);
      expect(body['lng'], 120.9842);
    });

    test('does nothing when neither WiFi nor GPS was detected', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      final service = serviceWith(client);

      final ok = await service.reportDetectedNetwork();

      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('a server error is reported as failure, not thrown', () async {
      final client = MockClient((_) async => http.Response('', 500));
      final service = serviceWith(client);

      final ok = await service.reportDetectedNetwork(wifiSsid: 'X');

      expect(ok, isFalse);
    });

    test('a network exception is swallowed and reported as failure', () async {
      final client = MockClient((_) async => throw Exception('offline'));
      final service = serviceWith(client);

      await expectLater(service.reportDetectedNetwork(wifiSsid: 'X'), completion(isFalse));
    });
  });

  group('unpair()', () {
    test('clears the network-setup flag along with everything else', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'apiKey': 'k', 'deviceId': 1, 'companyId': 1, 'companyName': 'Acme'}),
          201,
        ),
      );
      final service = serviceWith(client);
      await service.load();
      await service.pair('CODE1234');
      await service.finishNetworkSetup();
      expect(service.state.value, ProvisioningState.ready);

      await service.unpair();

      expect(service.isPaired, isFalse);
      // No compiled-in MOBILE_API_KEY in the test binary, so an unpaired
      // device with nothing to fall back on is unprovisioned again.
      expect(service.state.value, ProvisioningState.unprovisioned);
      expect(await fakePlatform.read(key: 'kiosk_network_setup_done', options: {}), isNull);
    });
  });
}
