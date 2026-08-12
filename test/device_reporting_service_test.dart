import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app/services/device_reporting_service.dart';
import 'package:mobile_app/services/local_database_service.dart';

/// Records what the reporting service does to the local queue.
///
/// noSuchMethod stands in for the rest of LocalDatabaseService's surface so
/// this stays a fake of the two calls that matter here, rather than a
/// reimplementation of the whole class.
class _FakeLocalDb implements LocalDatabaseService {
  final List<int> markedUploaded = [];
  int inserted = 0;

  @override
  Future<int> insertErrorReport({
    required String level,
    required String message,
    String? context,
    String? appVersion,
  }) async {
    inserted += 1;
    return inserted;
  }

  @override
  Future<void> markErrorReportsUploaded(List<int> ids) async {
    markedUploaded.addAll(ids);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  // The bug: package:http only throws on transport failures, so a 401/403/500
  // came back as an ordinary Response and _post returned normally. reportError
  // took that as proof of delivery and deleted the queued row — silently
  // destroying exactly the reports sent while the kiosk API key was rejected.
  test('a report the server rejects stays queued instead of being marked sent', () async {
    for (final status in [401, 403, 429, 500]) {
      final db = _FakeLocalDb();
      final client = MockClient((request) async => http.Response('nope', status));
      final service = DeviceReportingService.forTesting(client: client, localDb: db);

      await service.reportError('something broke');

      expect(db.inserted, 1, reason: 'HTTP $status: report should be queued locally');
      expect(
        db.markedUploaded,
        isEmpty,
        reason: 'HTTP $status: a rejected report must not be recorded as delivered',
      );
    }
  });

  test('a report the server accepts is marked delivered', () async {
    final db = _FakeLocalDb();
    final client = MockClient((request) async => http.Response('{"success":true}', 200));
    final service = DeviceReportingService.forTesting(client: client, localDb: db);

    await service.reportError('something broke');

    expect(db.markedUploaded, [1]);
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
