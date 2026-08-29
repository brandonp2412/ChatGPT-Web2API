import 'package:flutter_test/flutter_test.dart';
import 'package:sloppa/src/api/bridge_client.dart';

void main() {
  group('BridgeSettings', () {
    test('permits HTTPS bridge URLs', () {
      expect(
        BridgeSettings.validateBaseUrl('https://bridge.example.com'),
        isNull,
      );
    });

    test('permits loopback HTTP for local development', () {
      expect(BridgeSettings.validateBaseUrl('http://127.0.0.1:8080'), isNull);
      expect(BridgeSettings.validateBaseUrl('http://localhost:8080'), isNull);
      expect(BridgeSettings.validateBaseUrl('http://[::1]:8080'), isNull);
    });

    test('rejects remote plaintext HTTP', () {
      expect(
        BridgeSettings.validateBaseUrl('http://192.168.1.20:8080'),
        contains('HTTPS'),
      );
    });

    test('rejects embedded URL credentials', () {
      expect(
        BridgeSettings.validateBaseUrl('https://user:pass@bridge.example.com'),
        contains('credentials'),
      );
    });

    test('rejects query and fragment components', () {
      expect(
        BridgeSettings.validateBaseUrl('https://bridge.example.com?token=x'),
        contains('query'),
      );
      expect(
        BridgeSettings.validateBaseUrl('https://bridge.example.com/#secret'),
        contains('query'),
      );
    });

    test('normalizes trailing slashes', () {
      expect(
        BridgeSettings.normalizedBaseUrl('https://example.com///'),
        'https://example.com',
      );
    });

    test('rejects empty and non-network URLs', () {
      expect(BridgeSettings.validateBaseUrl(''), isNotNull);
      expect(BridgeSettings.validateBaseUrl('file:///tmp/bridge'), isNotNull);
    });

    test('rejects malformed ports', () {
      expect(
        BridgeSettings.validateBaseUrl('https://bridge.example.com:bad'),
        isNotNull,
      );
    });
  });
}
