import 'dart:convert';

import 'package:chatgpt_bridge_client/src/api/bridge_client.dart';
import 'package:chatgpt_bridge_client/src/api/parity_actions_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('conversation IDs are encoded exactly once and auth stays on bridge', () async {
    const id = 'a/b % c';
    late Uri requested;
    final mock = MockClient((http.Request request) async {
      requested = request.url;
      expect(request.headers['Authorization'], 'Bearer secret');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'data': <String, dynamic>{
            'id': id,
            'title': 'Encoded ID',
            'messages': <dynamic>[],
            'nodes': <String, dynamic>{},
          },
        }),
        200,
      );
    });
    final client = BridgeClient(
      const BridgeSettings(
        baseUrl: 'https://bridge.example/api',
        apiKey: 'secret',
      ),
      httpClient: mock,
    );

    final conversation = await client.conversation(id);

    expect(conversation.id, id);
    expect(
      requested.toString(),
      'https://bridge.example/api/v1/conversations/a%2Fb%20%25%20c',
    );
    expect(requested.toString(), isNot(contains('%252F')));
  });

  test('parity action IDs are encoded exactly once', () async {
    const id = 'a/b % c';
    late Uri requested;
    final mock = MockClient((http.Request request) async {
      requested = request.url;
      return http.Response('{}', 200);
    });
    final api = ParityActionsApi(
      const BridgeSettings(baseUrl: 'https://bridge.example/api'),
      client: mock,
    );

    await api.setPinned(id, true);

    expect(
      requested.toString(),
      'https://bridge.example/api/v1/conversations/a%2Fb%20%25%20c/pin',
    );
    expect(requested.toString(), isNot(contains('%252F')));
  });
}
