import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api/bridge_client.dart';
import 'voice_api.dart';

enum VoiceSessionState {
  idle,
  requestingMicrophone,
  negotiating,
  connected,
  failed,
  ended,
}

class VoiceSession extends ChangeNotifier {
  VoiceSession({
    required this.settings,
    this.conversationId,
    this.projectId,
    this.voice = 'cove',
  }) : _api = VoiceApi(settings);

  static const List<String> supportedVoices = <String>[
    'breeze',
    'cove',
    'ember',
    'fathom',
    'glimmer',
    'juniper',
    'maple',
    'orbit',
    'vale',
  ];

  final BridgeSettings settings;
  final String? conversationId;
  final String? projectId;
  final VoiceApi _api;
  final Random _random = Random.secure();

  String voice;
  VoiceSessionState state = VoiceSessionState.idle;
  String? errorMessage;
  String? sessionId;
  String? lastEventType;
  String? transcript;
  bool muted = false;
  bool sendingRelay = false;

  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  RTCDataChannel? _dataChannel;
  RTCVideoRenderer? _remoteRenderer;
  bool _disposed = false;

  bool get active => state == VoiceSessionState.requestingMicrophone ||
      state == VoiceSessionState.negotiating ||
      state == VoiceSessionState.connected;

  bool get relayReady => state == VoiceSessionState.connected &&
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  Future<void> start() async {
    if (active || _disposed) {
      return;
    }
    errorMessage = null;
    transcript = null;
    lastEventType = null;
    state = VoiceSessionState.requestingMicrophone;
    notifyListeners();

    try {
      final local = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': <String, dynamic>{
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      _localStream = local;

      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _remoteRenderer = renderer;

      final peer = await createPeerConnection(<String, dynamic>{
        'iceServers': <dynamic>[],
        'sdpSemantics': 'unified-plan',
      });
      _peer = peer;
      peer.onConnectionState = _onConnectionState;
      peer.onTrack = (RTCTrackEvent event) {
        if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
        }
      };

      // ChatGPT Web Voice uses negotiated DataChannel id 0. Creating a normal
      // in-band channel can work in some browsers but does not match the web
      // client's realtime transport contract.
      final dataInit = RTCDataChannelInit()
        ..ordered = true
        ..negotiated = true
        ..id = 0;
      final dataChannel = await peer.createDataChannel('oai-events', dataInit);
      _dataChannel = dataChannel;
      dataChannel.onMessage = _onDataMessage;
      dataChannel.onDataChannelState = (RTCDataChannelState _) {
        if (!_disposed) {
          notifyListeners();
        }
      };

      for (final track in local.getAudioTracks()) {
        await peer.addTrack(track, local);
      }

      state = VoiceSessionState.negotiating;
      notifyListeners();

      final offer = await peer.createOffer(<String, dynamic>{
        'offerToReceiveAudio': true,
      });
      await peer.setLocalDescription(offer);
      await _waitForIceGathering(peer);
      final localDescription = await peer.getLocalDescription();
      final offerSdp = localDescription?.sdp;
      if (offerSdp == null || !offerSdp.trimLeft().startsWith('v=0')) {
        throw const BridgeException('WebRTC did not produce a valid voice offer');
      }

      final negotiation = await _api.negotiate(
        offerSdp: offerSdp,
        voice: voice,
        conversationId: conversationId,
        projectId: projectId,
      );
      sessionId = negotiation.sessionId;
      voice = negotiation.voice;
      await peer.setRemoteDescription(
        RTCSessionDescription(negotiation.answerSdp, 'answer'),
      );

      if (peer.connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        state = VoiceSessionState.connected;
      }
      notifyListeners();
    } on Object catch (error) {
      errorMessage = _errorText(error);
      state = VoiceSessionState.failed;
      notifyListeners();
      await _closeTransport();
    }
  }

  Future<void> sendText(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || sendingRelay) {
      return;
    }
    sendingRelay = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _sendRelayMessage(_baseUserMessage(<String, dynamic>{
        'content_type': 'text',
        'parts': <String>[clean],
      }));
    } on Object catch (error) {
      errorMessage = _errorText(error);
      rethrow;
    } finally {
      sendingRelay = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> sendImage(File file, {String text = ''}) async {
    if (sendingRelay) {
      return;
    }
    sendingRelay = true;
    errorMessage = null;
    notifyListeners();
    try {
      final attachment = await _api.uploadImage(file);
      final parts = <dynamic>[
        <String, dynamic>{
          'content_type': 'image_asset_pointer',
          'asset_pointer': attachment.assetPointer,
          'size_bytes': attachment.size,
          'width': attachment.width,
          'height': attachment.height,
        },
        if (text.trim().isNotEmpty) text.trim(),
      ];
      final message = _baseUserMessage(<String, dynamic>{
        'content_type': 'multimodal_text',
        'parts': parts,
      });
      (message['metadata'] as Map<String, dynamic>)['attachments'] =
          <Map<String, dynamic>>[
        <String, dynamic>{
          'id': attachment.fileId,
          'size': attachment.size,
          'name': attachment.name,
          'mimeType': attachment.mimeType,
          'width': attachment.width,
          'height': attachment.height,
        },
      ];
      await _sendRelayMessage(message);
    } on Object catch (error) {
      errorMessage = _errorText(error);
      rethrow;
    } finally {
      sendingRelay = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> interrupt() async {
    await _sendDataEvent(<String, dynamic>{
      'type': 'action_request',
      'payload': <String, dynamic>{'action': 'stop_speaking'},
    });
  }

  Future<void> setMuted(bool value) async {
    muted = value;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !value;
      }
    }
    notifyListeners();
  }

  Future<void> stop() async {
    if (state == VoiceSessionState.ended || state == VoiceSessionState.idle) {
      return;
    }
    await _closeTransport();
    state = VoiceSessionState.ended;
    notifyListeners();
  }

  Future<void> _sendRelayMessage(Map<String, dynamic> message) {
    return _sendDataEvent(<String, dynamic>{
      'type': 'relay_message',
      'payload': <String, dynamic>{
        'type': 'relay_message',
        'message': message,
      },
    });
  }

  Future<void> _sendDataEvent(Map<String, dynamic> event) async {
    final channel = _dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw const BridgeException('Live Voice data channel is not ready');
    }
    final envelope = <String, dynamic>{
      'type': 'data_message',
      'data': jsonEncode(event),
    };
    await channel.send(RTCDataChannelMessage(jsonEncode(envelope)));
  }

  Map<String, dynamic> _baseUserMessage(Map<String, dynamic> content) {
    return <String, dynamic>{
      'id': _uuidV4(),
      'author': <String, dynamic>{'role': 'user'},
      'create_time': DateTime.now().millisecondsSinceEpoch / 1000,
      'content': content,
      'metadata': <String, dynamic>{
        'serialization_metadata': <String, dynamic>{
          'custom_symbol_offsets': <dynamic>[],
        },
      },
      'clientMetadata': <String, dynamic>{'isOptimistic': true},
    };
  }

  String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    final value = bytes.map(hex).join();
    return '${value.substring(0, 8)}-'
        '${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-'
        '${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  void _onConnectionState(RTCPeerConnectionState connectionState) {
    if (_disposed) {
      return;
    }
    if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      state = VoiceSessionState.connected;
    } else if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      state = VoiceSessionState.failed;
      errorMessage ??= 'Voice connection failed';
    } else if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      if (state == VoiceSessionState.connected) {
        state = VoiceSessionState.failed;
        errorMessage ??= 'Voice connection disconnected';
      }
    } else if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      if (state != VoiceSessionState.failed) {
        state = VoiceSessionState.ended;
      }
    }
    notifyListeners();
  }

  void _onDataMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      return;
    }
    final text = message.text.trim();
    if (text.isEmpty) {
      return;
    }
    try {
      var decoded = jsonDecode(text);
      if (decoded is Map && decoded['type'] == 'data_message') {
        final inner = decoded['data'];
        if (inner is String) {
          decoded = jsonDecode(inner);
        }
      }
      if (decoded is Map) {
        final event = decoded.cast<String, dynamic>();
        lastEventType = event['type']?.toString();
        final candidate = _findTranscript(event);
        if (candidate != null && candidate.isNotEmpty) {
          transcript = candidate;
        }
      }
    } on FormatException {
      lastEventType = 'text';
    }
    notifyListeners();
  }

  String? _findTranscript(Map<String, dynamic> event) {
    for (final key in <String>['transcript', 'text', 'delta']) {
      final value = event[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    final payload = event['payload'];
    if (payload is Map) {
      final nested = _findTranscript(payload.cast<String, dynamic>());
      if (nested != null) {
        return nested;
      }
    }
    final item = event['item'];
    if (item is Map) {
      final content = item['content'];
      if (content is List) {
        final parts = <String>[];
        for (final entry in content) {
          if (entry is Map) {
            final value = entry['transcript'] ?? entry['text'];
            if (value is String && value.trim().isNotEmpty) {
              parts.add(value.trim());
            }
          }
        }
        if (parts.isNotEmpty) {
          return parts.join('\n');
        }
      }
    }
    final message = event['message'];
    if (message is Map && message['content'] is Map) {
      final content = message['content'] as Map;
      final parts = content['parts'];
      if (parts is List) {
        final textParts = parts
            .whereType<String>()
            .where((String part) => part.trim().isNotEmpty)
            .toList(growable: false);
        if (textParts.isNotEmpty) {
          return textParts.join('\n');
        }
      }
    }
    return null;
  }

  Future<void> _waitForIceGathering(RTCPeerConnection peer) async {
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    peer.onIceGatheringState = (RTCIceGatheringState iceState) {
      if (iceState == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Host candidates are often already present in the local description.
    } finally {
      peer.onIceGatheringState = null;
    }
  }

  Future<void> _closeTransport() async {
    final channel = _dataChannel;
    _dataChannel = null;
    if (channel != null) {
      try {
        await channel.close();
      } on Object {
        // Best-effort teardown.
      }
    }

    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } on Object {
          // Best-effort teardown.
        }
      }
      try {
        await stream.dispose();
      } on Object {
        // Best-effort teardown.
      }
    }

    final peer = _peer;
    _peer = null;
    if (peer != null) {
      try {
        await peer.close();
      } on Object {
        // Best-effort teardown.
      }
    }

    final renderer = _remoteRenderer;
    _remoteRenderer = null;
    if (renderer != null) {
      renderer.srcObject = null;
      try {
        await renderer.dispose();
      } on Object {
        // Best-effort teardown.
      }
    }
  }

  String _errorText(Object error) {
    if (error is BridgeException) {
      return error.message;
    }
    return 'Voice failed: $error';
  }

  @override
  void dispose() {
    _disposed = true;
    _api.close();
    unawaited(_closeTransport());
    super.dispose();
  }
}
