import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/bridge_client.dart';

class VoiceNegotiation {
  const VoiceNegotiation({
    required this.answerSdp,
    required this.sessionId,
    required this.voice,
    required this.voiceMode,
  });

  final String answerSdp;
  final String sessionId;
  final String voice;
  final String voiceMode;

  factory VoiceNegotiation.fromJson(Map<String, dynamic> json) {
    final answerSdp = (json['answer_sdp'] ?? '').toString();
    if (!answerSdp.trimLeft().startsWith('v=0')) {
      throw const BridgeException('Bridge returned invalid voice SDP');
    }
    return VoiceNegotiation(
      answerSdp: answerSdp,
      sessionId: (json['voice_session_id'] ?? '').toString(),
      voice: (json['voice'] ?? 'cove').toString(),
      voiceMode: (json['voice_mode'] ?? 'wingman').toString(),
    );
  }
}

class VoiceAttachment {
  const VoiceAttachment({
    required this.fileId,
    required this.assetPointer,
    required this.name,
    required this.mimeType,
    required this.size,
    this.width = 0,
    this.height = 0,
  });

  final String fileId;
  final String assetPointer;
  final String name;
  final String mimeType;
  final int size;
  final int width;
  final int height;

  factory VoiceAttachment.fromJson(Map<String, dynamic> json) {
    int number(String snake, [String? camel]) {
      final value = json[snake] ?? (camel == null ? null : json[camel]);
      return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    }

    final fileId = (json['file_id'] ?? json['id'] ?? '').toString();
    final pointer = (json['asset_pointer'] ?? '').toString();
    if (fileId.isEmpty || pointer.isEmpty) {
      throw const BridgeException('Bridge returned malformed voice attachment');
    }
    return VoiceAttachment(
      fileId: fileId,
      assetPointer: pointer,
      name: (json['file_name'] ?? json['name'] ?? 'image').toString(),
      mimeType:
          (json['mime_type'] ?? json['mimeType'] ?? 'image/jpeg').toString(),
      size: number('file_size', 'size'),
      width: number('width'),
      height: number('height'),
    );
  }
}

class VoiceApi {
  VoiceApi(this.settings, {http.Client? client}) : _http = client ?? http.Client();

  final BridgeSettings settings;
  final http.Client _http;

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        if (settings.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
      };

  Uri _uri(String path) {
    final root = BridgeSettings.normalizedBaseUrl(settings.baseUrl);
    final suffix = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$root$suffix');
  }

  Future<VoiceNegotiation> negotiate({
    required String offerSdp,
    String voice = 'cove',
    String? conversationId,
    String? projectId,
  }) async {
    final response = await _http.post(
      _uri('/v1/voice/session'),
      headers: <String, String>{
        ..._headers,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'offer_sdp': offerSdp,
        'voice': voice,
        'voice_mode': 'wingman',
        'language_code': 'auto',
        if (conversationId != null && conversationId.isNotEmpty)
          'conversation_id': conversationId,
        if (projectId != null && projectId.isNotEmpty) 'project_id': projectId,
      }),
    ).timeout(const Duration(seconds: 90));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const BridgeException('Bridge returned malformed voice JSON');
    }
    return VoiceNegotiation.fromJson(decoded.cast<String, dynamic>());
  }

  Future<VoiceAttachment> uploadImage(File file) async {
    final stagedRequest = http.MultipartRequest('POST', _uri('/v1/attachments'));
    stagedRequest.headers.addAll(_headers);
    stagedRequest.files.add(await http.MultipartFile.fromPath('file', file.path));
    final stagedResponse = await _http.send(stagedRequest).timeout(
          const Duration(minutes: 3),
        );
    final stagedBody = await stagedResponse.stream.bytesToString();
    if (stagedResponse.statusCode < 200 || stagedResponse.statusCode >= 300) {
      throw _error(stagedResponse.statusCode, stagedBody);
    }
    final stagedDecoded = jsonDecode(stagedBody);
    if (stagedDecoded is! Map || stagedDecoded['data'] is! Map) {
      throw const BridgeException('Bridge returned malformed staged attachment');
    }
    final stagedData = (stagedDecoded['data'] as Map).cast<String, dynamic>();
    final attachmentId = (stagedData['id'] ?? '').toString();
    if (attachmentId.isEmpty) {
      throw const BridgeException('Bridge returned no staged attachment ID');
    }

    final response = await _http.post(
      _uri('/v1/voice/attachments'),
      headers: <String, String>{
        ..._headers,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{'attachment_id': attachmentId}),
    ).timeout(const Duration(minutes: 3));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['data'] is! Map) {
      throw const BridgeException('Bridge returned malformed voice attachment');
    }
    final data = (decoded['data'] as Map).cast<String, dynamic>();
    return VoiceAttachment.fromJson(<String, dynamic>{
      ...stagedData,
      ...data,
    });
  }

  BridgeException _error(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          return BridgeException(
            (error['message'] ?? 'Voice request failed').toString(),
            statusCode: statusCode,
            code: error['code']?.toString() ?? error['type']?.toString(),
          );
        }
      }
    } on FormatException {
      // Preserve the HTTP status when the bridge returns a non-JSON error.
    }
    return BridgeException(
      'Voice request failed (HTTP $statusCode)',
      statusCode: statusCode,
    );
  }

  void close() => _http.close();
}
