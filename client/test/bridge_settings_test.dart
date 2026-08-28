import 'package:chatgpt_bridge_client/src/api/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
    });

    test('rejects remote plaintext HTTP', () {
      expect(
        BridgeSettings.validateBaseUrl('http://192.168.1.20:8080'),
        contains('HTTPS'),
      );
    });

    test('normalizes trailing slashes', () {
      expect(
        BridgeSettings.normalizedBaseUrl('https://example.com///'),
        'https://example.com',
      );
    });
  });
}
