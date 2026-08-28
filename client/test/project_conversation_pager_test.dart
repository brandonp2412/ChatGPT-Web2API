import 'dart:convert';

import 'package:chatgpt_bridge_client/src/api/bridge_client.dart';
import 'package:chatgpt_bridge_client/src/api/project_conversation_pager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('project pager follows cursors and keeps bridge auth on bridge requests', () async {
    final cursors = <String>[];
    final mock = MockClient((http.Request request) async {
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'bridge.example');
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(request.url.path, '/api/v1/projects/project%201/conversations');
      final cursor = request.url.queryParameters['cursor']!;
      cursors.add(cursor);

      final page = switch (cursor) {
        '0' => <String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'a', 'title': 'A'},
              <String, dynamic>{'id': 'b', 'title': 'B'},
            ],
            'cursor': 'next-1',
          },
        'next-1' => <String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'b', 'title': 'B duplicate'},
              <String, dynamic>{'id': 'c', 'title': 'C'},
            ],
            'next_cursor': 'next-2',
          },
        _ => <String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'd', 'title': 'D'},
            ],
            'cursor': null,
          },
      };
      return http.Response(
        jsonEncode(<String, dynamic>{'data': page}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final items = await loadAllProjectConversations(
      settings: const BridgeSettings(
        baseUrl: 'https://bridge.example/api',
        apiKey: 'secret',
      ),
      projectId: 'project 1',
      httpClient: mock,
    );

    expect(items.map((item) => item.id), <String>['a', 'b', 'c', 'd']);
    expect(cursors, <String>['0', 'next-1', 'next-2']);
  });

  test('project pager rejects non-success bridge responses', () async {
    final mock = MockClient(
      (http.Request request) async => http.Response('unavailable', 503),
    );

    expect(
      () => loadAllProjectConversations(
        settings: const BridgeSettings(baseUrl: 'https://bridge.example'),
        projectId: 'project',
        httpClient: mock,
      ),
      throwsA(
        isA<BridgeException>().having(
          (BridgeException error) => error.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
  });
}
