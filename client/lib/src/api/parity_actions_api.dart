import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../model/account_models.dart';
import '../model/chat_models.dart';
import 'bridge_client.dart';

class ParityActionsApi {
  ParityActionsApi(this.settings, {http.Client? client})
      : _http = client ?? http.Client();

  final BridgeSettings settings;
  final http.Client _http;

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        if (settings.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = settings.baseUri;
    return base.replace(
      path: '${base.path}$path'.replaceAll('//', '/'),
      queryParameters: query,
    );
  }

  Future<ChatConversation> blockAction({
    required String conversationId,
    required String messageId,
    required String action,
    String? text,
  }) async {
    final response = await _post(
      '/v1/conversations/${Uri.encodeComponent(conversationId)}'
      '/blocks/${Uri.encodeComponent(messageId)}/actions',
      <String, dynamic>{
        'action': action,
        if (text != null) 'text': text,
      },
    );
    final conversation = response['conversation'];
    if (conversation is! Map) {
      throw const BridgeException('Bridge returned a malformed block action');
    }
    return ChatConversation.fromJson(conversation.cast<String, dynamic>());
  }

  Future<Set<String>> pinnedConversationIds() async {
    final response = await _get('/v1/pins');
    final result = <String>{};

    void visit(dynamic value) {
      if (value is Map) {
        final id = value['conversation_id'] ?? value['conversationId'];
        if (id != null && id.toString().trim().isNotEmpty) {
          result.add(id.toString().trim());
        }
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      }
    }

    visit(response['data']);
    return result;
  }

  Future<void> setPinned(String conversationId, bool pinned) async {
    await _patch(
      '/v1/conversations/${Uri.encodeComponent(conversationId)}/pin',
      <String, dynamic>{'pinned': pinned},
    );
  }

  Future<void> feedback({
    required String conversationId,
    required String messageId,
    required String rating,
    String? text,
  }) async {
    await _post(
      '/v1/conversations/${Uri.encodeComponent(conversationId)}/feedback',
      <String, dynamic>{
        'message_id': messageId,
        'rating': rating,
        if (text?.trim().isNotEmpty == true) 'text': text!.trim(),
      },
    );
  }

  Future<ShareResult> shareConversation(
    String conversationId, {
    bool anonymous = true,
  }) async {
    final response = await _post(
      '/v1/conversations/${Uri.encodeComponent(conversationId)}/share',
      <String, dynamic>{'anonymous': anonymous},
    );
    final data = response['data'];
    if (data is! Map) {
      throw const BridgeException('Bridge returned malformed share data');
    }
    return ShareResult.fromJson(data.cast<String, dynamic>());
  }

  Future<void> deleteShare(String shareId) async {
    await _delete('/v1/shares/${Uri.encodeComponent(shareId)}');
  }

  Future<List<MemoryItem>> memories() async {
    final response = await _get('/v1/memories');
    final data = response['data'];
    if (data is! List) {
      return const <MemoryItem>[];
    }
    return data
        .whereType<Map>()
        .map((Map item) => MemoryItem.fromJson(item.cast<String, dynamic>()))
        .where((MemoryItem item) => item.id.isNotEmpty || item.content.isNotEmpty)
        .toList(growable: false);
  }

  Future<MemoryItem> createMemory(String content) async {
    final response = await _post('/v1/memories', <String, dynamic>{
      'content': content,
    });
    final data = response['data'];
    if (data is! Map) {
      throw const BridgeException('Bridge returned malformed memory data');
    }
    return MemoryItem.fromJson(data.cast<String, dynamic>());
  }

  Future<void> deleteMemory(String memoryId) async {
    await _delete('/v1/memories/${Uri.encodeComponent(memoryId)}');
  }

  Future<ProjectSummary> createProject({
    required String name,
    String instructions = '',
    String memoryScope = 'project_v2',
  }) async {
    final response = await _post('/v1/projects', <String, dynamic>{
      'name': name,
      'instructions': instructions,
      'memory_scope': memoryScope,
    });
    final data = response['data'];
    if (data is! Map) {
      throw const BridgeException('Bridge returned malformed project data');
    }
    return ProjectSummary.fromJson(data.cast<String, dynamic>());
  }

  Future<ProjectSummary> updateProjectInstructions(
    String projectId,
    String instructions,
  ) async {
    final response = await _patch(
      '/v1/projects/${Uri.encodeComponent(projectId)}',
      <String, dynamic>{'instructions': instructions},
    );
    final data = response['data'];
    if (data is! Map) {
      throw const BridgeException('Bridge returned malformed project data');
    }
    return ProjectSummary.fromJson(data.cast<String, dynamic>());
  }

  Future<void> deleteProject(String projectId) async {
    await _delete('/v1/projects/${Uri.encodeComponent(projectId)}');
  }

  Future<List<ProjectFile>> projectFiles(String projectId) async {
    final response = await _get(
      '/v1/projects/${Uri.encodeComponent(projectId)}/files',
    );
    final data = response['data'];
    final raw = data is Map
        ? data['items'] ?? data['files'] ?? data['data']
        : data;
    if (raw is! List) {
      return const <ProjectFile>[];
    }
    return raw
        .whereType<Map>()
        .map((Map item) => ProjectFile.fromJson(item.cast<String, dynamic>()))
        .where((ProjectFile item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<Uint8List> projectFileBytes(
    String projectId,
    String fileId,
  ) async {
    final response = await _http.get(
      _uri(
        '/v1/projects/${Uri.encodeComponent(projectId)}'
        '/files/${Uri.encodeComponent(fileId)}/download',
        const <String, String>{'inline': '1'},
      ),
      headers: <String, String>{
        ..._headers,
        'Accept': '*/*',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    return response.bodyBytes;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await _http.get(_uri(path), headers: _headers);
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _http.post(
      _uri(path),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _http.patch(
      _uri(path),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    final response = await _http.delete(_uri(path), headers: _headers);
    return _decodeResponse(response, allowEmpty: true);
  }

  Map<String, dynamic> _decodeResponse(
    http.Response response, {
    bool allowEmpty = false,
  }) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    if (response.body.trim().isEmpty && allowEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const BridgeException('Bridge returned malformed JSON');
    }
    return decoded.cast<String, dynamic>();
  }

  BridgeException _error(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = (decoded['error'] as Map).cast<String, dynamic>();
        return BridgeException(
          (error['message'] ?? 'Bridge request failed').toString(),
          statusCode: statusCode,
          code: error['code']?.toString() ?? error['type']?.toString(),
        );
      }
    } on FormatException {
      // Keep the HTTP status for non-JSON upstream errors.
    }
    return BridgeException(
      'Bridge request failed (HTTP $statusCode)',
      statusCode: statusCode,
    );
  }

  void close() => _http.close();
}
