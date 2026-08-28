import 'dart:convert';

import 'package:http/http.dart' as http;

import '../model/chat_models.dart';
import '../state/pagination.dart';
import 'bridge_client.dart';

Future<List<ConversationSummary>> loadAllProjectConversations({
  required BridgeSettings settings,
  required String projectId,
  http.Client? httpClient,
}) async {
  final ownedClient = httpClient == null;
  final client = httpClient ?? http.Client();
  try {
    return collectCursorPages<ConversationSummary>(
      loadPage: (String cursor) => _loadProjectPage(
        client: client,
        settings: settings,
        projectId: projectId,
        cursor: cursor,
      ),
      idOf: (ConversationSummary item) => item.id,
    );
  } finally {
    if (ownedClient) {
      client.close();
    }
  }
}

Future<CursorPage<ConversationSummary>> _loadProjectPage({
  required http.Client client,
  required BridgeSettings settings,
  required String projectId,
  required String cursor,
}) async {
  final base = settings.baseUri;
  final uri = base.replace(
    path: '${base.path}/v1/projects/${Uri.encodeComponent(projectId)}/conversations'
        .replaceAll('//', '/'),
    queryParameters: <String, String>{'cursor': cursor},
  );
  final response = await client.get(
    uri,
    headers: <String, String>{
      'Accept': 'application/json',
      if (settings.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${settings.apiKey.trim()}',
    },
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw BridgeException(
      'Project conversations failed (HTTP ${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! Map) {
    throw const BridgeException('Bridge returned malformed project pagination');
  }
  final outer = decoded.cast<String, dynamic>();
  final dynamic rawData = outer['data'];
  if (rawData is! Map) {
    return CursorPage<ConversationSummary>(
      items: _conversationSummaries(rawData),
    );
  }

  final data = rawData.cast<String, dynamic>();
  final items = _conversationSummaries(
    data['items'] ?? data['conversations'] ?? data['data'],
  );
  final dynamic cursorValue = data['next_cursor'] ??
      data['nextCursor'] ??
      data['cursor'] ??
      data['next'];
  final nextCursor = cursorValue?.toString().trim();
  return CursorPage<ConversationSummary>(
    items: items,
    nextCursor: nextCursor == null || nextCursor.isEmpty ? null : nextCursor,
  );
}

List<ConversationSummary> _conversationSummaries(dynamic raw) {
  return raw is List
      ? raw
          .whereType<Map>()
          .map(
            (Map item) =>
                ConversationSummary.fromJson(item.cast<String, dynamic>()),
          )
          .where((ConversationSummary item) => item.id.isNotEmpty)
          .toList(growable: false)
      : const <ConversationSummary>[];
}
