import 'dart:convert';

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

class VoiceApi {
  VoiceApi(this.settings, {http.Client? client}) : _http = client ?? http.Client();

  final BridgeSettings settings;
  final http.Client _http;

  Future<VoiceNegotiation> negotiate({
    required String offerSdp,
    String voice = 'cove',
    String? conversationId,
    String? projectId,
  }) async {
    final base = settings.baseUri;
    final uri = base.replace(
      path: '${base.path}/v1/voice/session'.replaceAll('//', '/'),
      queryParameters: null,
    );
    final response = await _http.post(
      uri,
      headers: <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (settings.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
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
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response.statusCode, response.body);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const BridgeException('Bridge returned malformed voice JSON');
    }
    return VoiceNegotiation.fromJson(decoded.cast<String, dynamic>());
  }

  BridgeException _error(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          return BridgeException(
            (error['message'] ?? 'Voice negotiation failed').toString(),
            statusCode: statusCode,
            code: error['code']?.toString() ?? error['type']?.toString(),
          );
        }
      }
    } on FormatException {
      // Preserve the HTTP status when the bridge returns a non-JSON error.
    }
    return BridgeException(
      'Voice negotiation failed (HTTP $statusCode)',
      statusCode: statusCode,
    );
  }

  void close() => _http.close();
}
