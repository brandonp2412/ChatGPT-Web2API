import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sloppa/src/api/bridge_client.dart';
import 'package:sloppa/src/api/parity_actions_api.dart';

void main() {
  test('bridge GETs time out deterministically', () async {
    final neverCompletes = Completer<http.Response>();
    final client = BridgeClient(
      const BridgeSettings(baseUrl: 'http://127.0.0.1:8080'),
      httpClient: MockClient((_) => neverCompletes.future),
      requestTimeout: const Duration(milliseconds: 10),
    );

    expect(client.models(), throwsA(isA<TimeoutException>()));
  });

  test(
    'conversation IDs are encoded exactly once and auth stays on bridge',
    () async {
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
    },
  );

  test('malformed JSON becomes a user-facing bridge error', () async {
    final client = BridgeClient(
      const BridgeSettings(baseUrl: 'http://127.0.0.1:8080'),
      httpClient: MockClient((_) async => http.Response('not-json', 200)),
    );

    expect(
      client.models(),
      throwsA(
        isA<BridgeException>().having(
          (BridgeException error) => error.message,
          'message',
          'Bridge returned malformed JSON',
        ),
      ),
    );
  });

  test('oversized mutation responses are rejected before decoding', () async {
    final client = BridgeClient(
      const BridgeSettings(baseUrl: 'http://127.0.0.1:8080'),
      httpClient: MockClient(
        (_) async => http.Response('x' * (33 * 1024 * 1024), 200),
      ),
    );

    expect(
      client.renameConversation('c1', 'title'),
      throwsA(isA<BridgeException>()),
    );
  });

  test('SSE supports multiline data and stops at the done sentinel', () async {
    final client = BridgeClient(
      const BridgeSettings(baseUrl: 'http://127.0.0.1:8080'),
      httpClient: MockClient(
        (_) async => http.Response(
          'data: {"type":"text",\n'
          'data: "delta":"hello"}\n'
          '\n'
          'data: [DONE]\n'
          '\n'
          'data: {"type":"text","delta":"late"}\n'
          '\n',
          200,
          headers: <String, String>{'content-type': 'text/event-stream'},
        ),
      ),
    );

    final events = await client.send(prompt: 'test').toList();

    expect(events, hasLength(1));
    expect(events.single.delta, 'hello');
  });

  test(
    'SSE flushes a final event even without a trailing blank line',
    () async {
      final client = BridgeClient(
        const BridgeSettings(baseUrl: 'http://127.0.0.1:8080'),
        httpClient: MockClient(
          (_) async => http.Response(
            'data: {"type":"text","delta":"final"}',
            200,
            headers: <String, String>{'content-type': 'text/event-stream'},
          ),
        ),
      );

      final events = await client.send(prompt: 'test').toList();

      expect(events, hasLength(1));
      expect(events.single.delta, 'final');
    },
  );

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
