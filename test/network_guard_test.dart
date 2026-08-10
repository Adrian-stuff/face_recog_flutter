import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/widgets/network_guard.dart';

void main() {
  group('computeNetworkGuardAllowed', () {
    test('nothing enforced: always allowed', () {
      // A freshly-paired device with no location assigned yet must be
      // usable, not locked out by a check nobody has configured.
      expect(
        computeNetworkGuardAllowed(
          wifiEnforced: false,
          wifiOk: false,
          geoEnforced: false,
          geoOk: false,
        ),
        isTrue,
      );
    });

    group('only WiFi enforced', () {
      test('allowed when WiFi matches', () {
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: true,
            wifiOk: true,
            geoEnforced: false,
            geoOk: false,
          ),
          isTrue,
        );
      });

      test('blocked when WiFi does not match', () {
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: true,
            wifiOk: false,
            geoEnforced: false,
            geoOk: false,
          ),
          isFalse,
        );
      });
    });

    group('only GPS enforced', () {
      test('allowed when within the geofence', () {
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: false,
            wifiOk: false,
            geoEnforced: true,
            geoOk: true,
          ),
          isTrue,
        );
      });

      test('blocked when outside the geofence', () {
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: false,
            wifiOk: false,
            geoEnforced: true,
            geoOk: false,
          ),
          isFalse,
        );
      });
    });

    group('both WiFi and GPS enforced', () {
      test('allowed when both pass', () {
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: true,
            wifiOk: true,
            geoEnforced: true,
            geoOk: true,
          ),
          isTrue,
        );
      });

      test('blocked when WiFi fails, even though GPS proves the location', () {
        // WiFi is checked first and is authoritative: it is not a signal
        // GPS can override. Letting GPS bypass a WiFi mismatch would let
        // anyone get in just by spoofing/faking location, defeating the
        // point of enforcing WiFi at all.
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: true,
            wifiOk: false,
            geoEnforced: true,
            geoOk: true,
          ),
          isFalse,
        );
      });

      test('blocked when GPS fails but WiFi is on the right network', () {
        // Symmetric case, and still AND semantics: WiFi passing doesn't
        // excuse a failing GPS check when GPS is also enforced.
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: true,
            wifiOk: true,
            geoEnforced: true,
            geoOk: false,
          ),
          isFalse,
        );
      });

      test('blocked when both fail', () {
        expect(
          computeNetworkGuardAllowed(
            wifiEnforced: true,
            wifiOk: false,
            geoEnforced: true,
            geoOk: false,
          ),
          isFalse,
        );
      });
    });
  });

  group('computeWifiOk', () {
    test('not connected to any WiFi and nothing required: ok', () {
      expect(
        computeWifiOk(
          currentSSID: null,
          requiredSSID: '',
          currentBSSID: null,
          requiredBSSID: '',
        ),
        isTrue,
      );
    });

    test('not connected to any WiFi but an SSID is required: fails', () {
      expect(
        computeWifiOk(
          currentSSID: null,
          requiredSSID: 'Office WiFi',
          currentBSSID: null,
          requiredBSSID: '',
        ),
        isFalse,
      );
    });

    test('SSID matches, BSSID not enforced: ok', () {
      expect(
        computeWifiOk(
          currentSSID: 'Office WiFi',
          requiredSSID: 'Office WiFi',
          currentBSSID: null,
          requiredBSSID: '',
        ),
        isTrue,
      );
    });

    test('SSID does not match: fails regardless of BSSID', () {
      expect(
        computeWifiOk(
          currentSSID: 'Coffee Shop WiFi',
          requiredSSID: 'Office WiFi',
          currentBSSID: 'aa:bb:cc:dd:ee:ff',
          requiredBSSID: 'aa:bb:cc:dd:ee:ff',
        ),
        isFalse,
      );
    });

    test('SSID matches and BSSID matches: ok', () {
      expect(
        computeWifiOk(
          currentSSID: 'Office WiFi',
          requiredSSID: 'Office WiFi',
          currentBSSID: 'aa:bb:cc:dd:ee:ff',
          requiredBSSID: 'aa:bb:cc:dd:ee:ff',
        ),
        isTrue,
      );
    });

    test('SSID matches but BSSID is a rogue AP with the same name: fails', () {
      // The exact case BSSID enforcement exists for: a spoofed SSID from a
      // different access point.
      expect(
        computeWifiOk(
          currentSSID: 'Office WiFi',
          requiredSSID: 'Office WiFi',
          currentBSSID: 'ff:ee:dd:cc:bb:aa',
          requiredBSSID: 'aa:bb:cc:dd:ee:ff',
        ),
        isFalse,
      );
    });

    test(
      'SSID matches but the device cannot read its own BSSID: ok, not a mismatch',
      () {
        // The regression this exists to catch: iOS can essentially never
        // report a real BSSID without a special Apple entitlement. Comparing
        // that null against a configured BSSID would lock out every iOS
        // kiosk the moment an admin adds a BSSID to a location, even while
        // sitting on the exact right SSID.
        expect(
          computeWifiOk(
            currentSSID: 'Office WiFi',
            requiredSSID: 'Office WiFi',
            currentBSSID: null,
            requiredBSSID: 'aa:bb:cc:dd:ee:ff',
          ),
          isTrue,
        );
      },
    );
  });
}
