import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../model/account_models.dart';
import '../model/chat_models.dart';

class BridgeSettings {
  const BridgeSettings({required this.baseUrl, this.apiKey = ''});

  final String baseUrl;
  final String apiKey;

  Uri get baseUri => Uri.parse(normalizedBaseUrl(baseUrl));

  BridgeSettings copyWith({String? baseUrl, String? apiKey}) => BridgeSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
      );

  static String normalizedBaseUrl(String input) {
    var value = input.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static String? validateBaseUrl(String value) {
    final normalized = normalizedBaseUrl(value);
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) {
      return 'Enter a valid bridge URL';
    }
    if (uri.userInfo.isNotEmpty) {
      return 'Bridge URLs must not contain embedded credentials';
    }
    if (uri.hasQuery || uri.hasFragment) {
      return 'Bridge URLs must not contain a query or fragment';
    }
    if (uri.scheme == 'https') {
      return null;
    }
    if (uri.scheme != 'http') {
      return 'Use HTTPS, or HTTP only for loopback';
    }
    final host = uri.host.toLowerCase();
    final loopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
    return loopback ? null : 'Non-loopback bridge URLs must use HTTPS';
  }
}

class BridgeException implements Exception {
  const BridgeException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => message;
}

class UploadedAttachment {
  const UploadedAttachment({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
  });

  final String id;
  final String name;
  final int size;
  final String mimeType;

  factory UploadedAttachment.fromJson(Map<String, dynamic> json) {
    return UploadedAttachment(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'attachment').toString(),
      size: json['size'] is num ? (json['size'] as num).toInt() : 0,
      mimeType: (json['mime_type'] ?? 'application/octet-stream').toString(),
    );
  }
}

class BridgeClient {
  BridgeClient(this.settings, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  BridgeSettings settings;
  final http.Client _http;

  void close() => _http.close();

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        if (settings.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
      };

  Uri _uri(String path, [Map<String, String?> query = const <String, String?>{}]) {
    final filtered = <String, String>{};
    for (final entry in query.entries) {
      final value = entry.value;
      if (value != null && value.isNotEmpty) {
        filtered[entry.key] = value;
      }
    }

    // Dynamic path segments are encoded at the call site with encodeComponent.
    // Parsing the already-encoded joined URI preserves those escapes. Passing
    // the same string through Uri.replace(path: ...) would escape '%' again.
    final root = BridgeSettings.normalizedBaseUrl(settings.baseUrl);
    final suffix = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$root$suffix');
    return filtered.isEmpty ? uri : uri.replace(queryParameters: filtered);
  }

  Future<Map<String, dynamic>> health() => _getMap('/health');

  Future<Map<String, dynamic>> capabilities() => _getMap('/v1/capabilities');

  Future<List<ConversationSummary>> conversations({
    int offset = 0,
    int limit = 50,
  }) async {
    final response = await _getMap(
      '/v1/conversations',
      <String, String?>{'offset': '$offset', 'limit': '$limit'},
    );
    return _conversationSummaries(response['data']);
  }

  Future<List<ConversationSummary>> searchConversations(String query) async {
    final response = await _getMap(
      '/v1/conversations/search',
      <String, String?>{'query': query},
    );
    final dynamic raw = response['data'] ?? response['items'] ?? response['conversations'];
    return _conversationSummaries(raw);
  }

  Future<ChatConversation> conversation(String id) async {
    final response = await _getMap('/v1/conversations/${Uri.encodeComponent(id)}');
    final data = response['data'];
    if (data is! Map) {
      throw const BridgeException('Bridge returned a malformed conversation');
    }
    return ChatConversation.fromJson(data.cast<String, dynamic>());
  }

  Future<ChatConversation> renameConversation(String id, String title) async {
    final response = await _patchMap(
      '/v1/conversations/${Uri.encodeComponent(id)}',
      <String, dynamic>{'title': title},
    );
    return _conversationFromField(response, 'data');
  }

  Future<ChatConversation> archiveConversation(String id, bool archived) async {
    final response = await _patchMap(
      '/v1/conversations/${Uri.encodeComponent(id)}',
      <String, dynamic>{'archived': archived},
    );
    return _conversationFromField(response, 'data');
  }

  Future<void> deleteConversation(String id) async {
    await _deleteMap('/v1/conversations/${Uri.encodeComponent(id)}');
  }

  Future<ChatConversation> messageAction({
    required String conversationId,
    required String action,
    String? messageId,
    String? text,
  }) async {
    final response = await _postMap(
      '/v1/conversations/${Uri.encodeComponent(conversationId)}/actions',
      <String, dynamic>{
        'action': action,
        if (messageId != null && messageId.isNotEmpty) 'message_id': messageId,
        if (text != null) 'text': text,
      },
    );
    return _conversationFromField(response, 'data');
  }

  Future<List<String>> models() async {
    final response = await _getMap('/v1/models');
    final data = response['data'];
    if (data is! List) {
      return const <String>[];
    }
    return data.map((dynamic item) {
      if (item is Map) {
        return (item['id'] ?? item['slug'] ?? '').toString();
      }
      return item.toString();
    }).where((String item) => item.isNotEmpty).toList(growable: false);
  }

  Future<List<String>> reasoningLevels() async {
    final response = await _getMap('/v1/reasoning-levels');
    final data = response['data'];
    return data is List
        ? data
            .map((dynamic item) => item.toString())
            .where((String item) => item.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
  }

  Future<List<String>> tools() async {
    final response = await _getMap('/v1/tools');
    final data = response['data'];
    if (data is! List) {
      return const <String>[];
    }
    return data.map((dynamic item) {
      if (item is Map) {
        return (item['label'] ?? item['name'] ?? '').toString();
      }
      return item.toString();
    }).where((String item) => item.isNotEmpty).toList(growable: false);
  }

  Future<List<ProjectSummary>> projects() async {
    final response = await _getMap('/v1/projects');
    final data = response['data'];
    return data is List
        ? data
            .whereType<Map>()
            .map((Map item) => ProjectSummary.fromJson(item.cast<String, dynamic>()))
            .where((ProjectSummary item) => item.id.isNotEmpty)
            .toList(growable: false)
        : const <ProjectSummary>[];
  }

  Future<List<ConversationSummary>> projectConversations(
    String projectId, {
    String cursor = '0',
  }) async {
    final response = await _getMap(
      '/v1/projects/${Uri.encodeComponent(projectId)}/conversations',
      <String, String?>{'cursor': cursor},
    );
    final data = response['data'];
    if (data is Map) {
      return _conversationSummaries(
        data['items'] ?? data['conversations'] ?? data['data'],
      );
    }
    return _conversationSummaries(data);
  }

  Future<List<GptSummary>> gpts() async {
    final response = await _getMap('/v1/gpts');
    final data = response['data'];
    return data is List
        ? data
            .whereType<Map>()
            .map((Map item) => GptSummary.fromJson(item.cast<String, dynamic>()))
            .where((GptSummary item) => item.id.isNotEmpty)
            .toList(growable: false)
        : const <GptSummary>[];
  }

  Future<List<LibraryItem>> library() async {
    final response = await _getMap('/v1/library');
    final data = response['data'];
    return data is List
        ? data
            .whereType<Map>()
            .map((Map item) => LibraryItem.fromJson(item.cast<String, dynamic>()))
            .where((LibraryItem item) => item.name.isNotEmpty)
            .toList(growable: false)
        : const <LibraryItem>[];
  }

  Future<List<InteractiveAction>> interactiveActions({String? conversationId}) async {
    final response = await _getMap(
      '/v1/ui-actions',
      <String, String?>{'conversation_id': conversationId},
    );
    final data = response['data'];
    return data is List
        ? data
            .whereType<Map>()
            .map((Map item) => InteractiveAction.fromJson(item.cast<String, dynamic>()))
            .where((InteractiveAction item) => item.label.isNotEmpty)
            .toList(growable: false)
        : const <InteractiveAction>[];
  }

  Future<void> triggerInteractiveAction({
    required String label,
    String? conversationId,
  }) async {
    await _postMap('/v1/ui-actions', <String, dynamic>{
      'label': label,
      if (conversationId != null && conversationId.isNotEmpty)
        'conversation_id': conversationId,
    });
  }

  Future<UploadedAttachment> uploadAttachment(File file) async {
    final request = http.MultipartRequest('POST', _uri('/v1/attachments'));
    request.headers.addAll(_headers);
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await _http.send(request);
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw _error(streamed.statusCode, body);
    }
    final decoded = _decodeMap(body);
    final data = decoded['data'];
    if (data is! Map) {
      throw const BridgeException('Bridge returned a malformed attachment');
    }
    return UploadedAttachment.fromJson(data.cast<String, dynamic>());
  }

  Stream<BridgeEvent> send({
    required String prompt,
    String? conversationId,
    String model = 'auto',
    String? reasoningLevel,
    String mode = 'normal',
    String? projectId,
    String? gizmoId,
    String? app,
    bool temporary = false,
    List<String> attachmentIds = const <String>[],
    List<String> libraryFiles = const <String>[],
  }) async* {
    final request = http.Request('POST', _uri('/v1/chat/send'));
    request.headers.addAll(<String, String>{
      ..._headers,
      'Accept': 'text/event-stream',
      'Content-Type': 'application/json',
    });
    request.body = jsonEncode(<String, dynamic>{
      'prompt': prompt,
      'stream': true,
      'model': model,
      if (conversationId != null && conversationId.isNotEmpty)
        'conversation_id': conversationId,
      if (reasoningLevel != null && reasoningLevel.isNotEmpty)
        'reasoning_level': reasoningLevel,
      if (mode.isNotEmpty && mode != 'normal') 'mode': mode,
      if (projectId != null && projectId.isNotEmpty) 'project_id': projectId,
      if (gizmoId != null && gizmoId.isNotEmpty) 'gizmo_id': gizmoId,
      if (app != null && app.isNotEmpty) 'plugin': app,
      if (temporary) 'temporary': true,
      if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
      if (libraryFiles.isNotEmpty) 'library_files': libraryFiles,
    });

    final response = await _http.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw _error(response.statusCode, body);
    }
    yield* _eventStream(response.stream);
  }

  Stream<BridgeEvent> backgroundEvents(
    String conversationId, {
    Duration timeout = const Duration(minutes: 15),
  }) async* {
    final request = http.Request(
      'GET',
      _uri(
        '/v1/conversations/${Uri.encodeComponent(conversationId)}/events',
        <String, String?>{'timeout': '${timeout.inSeconds}'},
      ),
    );
    request.headers.addAll(<String, String>{
      ..._headers,
      'Accept': 'text/event-stream',
    });
    final response = await _http.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw _error(response.statusCode, body);
    }
    yield* _eventStream(response.stream);
  }

  Future<ChatConversation?> selectBranch(
    String conversationId,
    String targetNodeId,
  ) async {
    final response = await _postMap(
      '/v1/conversations/${Uri.encodeComponent(conversationId)}/branch/select',
      <String, dynamic>{'target_node_id': targetNodeId},
    );
    final conversation = response['conversation'];
    return conversation is Map
        ? ChatConversation.fromJson(conversation.cast<String, dynamic>())
        : null;
  }

  Future<void> stop() async {
    await _postMap('/v1/chat/stop', const <String, dynamic>{});
  }

  Stream<BridgeEvent> _eventStream(Stream<List<int>> bytes) async* {
    await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) {
        continue;
      }
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') {
        continue;
      }
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          yield BridgeEvent(data: decoded.cast<String, dynamic>(), raw: payload);
        }
      } on FormatException {
        yield BridgeEvent(
          data: <String, dynamic>{'type': 'text', 'delta': payload},
          raw: payload,
        );
      }
    }
  }

  List<ConversationSummary> _conversationSummaries(dynamic raw) {
    return raw is List
        ? raw
            .whereType<Map>()
            .map((Map item) => ConversationSummary.fromJson(item.cast<String, dynamic>()))
            .where((ConversationSummary item) => item.id.isNotEmpty)
            .toList(growable: false)
        : const <ConversationSummary>[];
  }

  ChatConversation _conversationFromField(
    Map<String, dynamic> response,
    String field,
  ) {
    final data = response[field];
    if (data is! Map) {
      throw const BridgeException('Bridge returned a malformed conversation');
    }
    return ChatConversation.fromJson(data.cast<String, dynamic>());
  }

  Future<Map<String, dynamic>> _getMap(
    String path, [
    Map<String, String?> query = const <String, String?>{},
  ]) async {
    final response = await _http.get(_uri(path, query), headers: _headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    return _decodeMap(response.body);
  }

  Future<Map<String, dynamic>> _postMap(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _http.post(
      _uri(path),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    return response.body.trim().isEmpty
        ? <String, dynamic>{}
        : _decodeMap(response.body);
  }

  Future<Map<String, dynamic>> _patchMap(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _http.patch(
      _uri(path),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    return _decodeMap(response.body);
  }

  Future<Map<String, dynamic>> _deleteMap(String path) async {
    final response = await _http.delete(_uri(path), headers: _headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    return response.body.trim().isEmpty
        ? <String, dynamic>{}
        : _decodeMap(response.body);
  }

  Map<String, dynamic> _decodeMap(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const BridgeException('Bridge returned malformed JSON');
    }
    return decoded.cast<String, dynamic>();
  }

  BridgeException _error(int statusCode, String body) {
    try {
      final data = _decodeMap(body);
      final error = data['error'];
      if (error is Map) {
        return BridgeException(
          (error['message'] ?? 'Bridge request failed').toString(),
          statusCode: statusCode,
          code: error['code']?.toString() ?? error['type']?.toString(),
        );
      }
    } on Object {
      // Preserve the HTTP status when an upstream error body is not JSON.
    }
    return BridgeException(
      'Bridge request failed (HTTP $statusCode)',
      statusCode: statusCode,
    );
  }
}
