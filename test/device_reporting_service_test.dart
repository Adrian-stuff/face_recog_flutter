import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app/services/device_reporting_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'FaceAttendance',
      packageName: 'com.example.mobile_app',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
  });

  test('reportError posts the message, level, context and a stable device id', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{"success":true}', 200);
    });

    final service = DeviceReportingService.forTesting(client: client);

    await service.reportError('Something broke', context: 'stack trace here');
    await service.reportError('Something else broke');

    expect(requests, hasLength(2));
    expect(requests[0].url.path, '/api/mobile/error-log');
    expect(requests[0].headers['x-api-key'], isNotNull);

    final body1 = jsonDecode(requests[0].body) as Map<String, dynamic>;
    expect(body1['message'], 'Something broke');
    expect(body1['level'], 'error');
    expect(body1['context'], 'stack trace here');
    expect(body1['appVersion'], '1.2.3+45');
    expect(body1['deviceId'], isNotEmpty);

    final body2 = jsonDecode(requests[1].body) as Map<String, dynamic>;
    // Same service instance must reuse the same generated device id.
    expect(body2['deviceId'], body1['deviceId']);
  });

  test('reportSyncStatus posts pending/failed counts to the status endpoint', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{"success":true}', 200);
    });

    final service = DeviceReportingService.forTesting(client: client);
    await service.reportSyncStatus(pendingCount: 3, failedCount: 1);

    expect(requests, hasLength(1));
    expect(requests[0].url.path, '/api/mobile/sync-status');

    final body = jsonDecode(requests[0].body) as Map<String, dynamic>;
    expect(body['pendingCount'], 3);
    expect(body['failedCount'], 1);
  });

  test('a persisted device id is reused across service instances', () async {
    final client1 = MockClient((request) async => http.Response('{}', 200));
    final service1 = DeviceReportingService.forTesting(client: client1);
    await service1.reportError('first');

    final captured = <http.Request>[];
    final client2 = MockClient((request) async {
      captured.add(request);
      return http.Response('{}', 200);
    });
    final service2 = DeviceReportingService.forTesting(client: client2);
    await service2.reportError('second');

    expect(captured, hasLength(1));
    final body = jsonDecode(captured[0].body) as Map<String, dynamic>;
    expect(body['deviceId'], isNotEmpty);
  });

  test('network failures are swallowed and never thrown to the caller', () async {
    final client = MockClient((request) async {
      throw Exception('network down');
    });
    final service = DeviceReportingService.forTesting(client: client);

    await expectLater(
      service.reportError('will fail to send'),
      completes,
    );
    await expectLater(
      service.reportSyncStatus(pendingCount: 0, failedCount: 0),
      completes,
    );
  });
}
