import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api/bridge_client.dart';
import 'voice_api.dart';

enum VoiceSessionState { idle, requestingMicrophone, negotiating, connected, failed, ended }

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

  String voice;
  VoiceSessionState state = VoiceSessionState.idle;
  String? errorMessage;
  String? sessionId;
  String? lastEventType;
  String? transcript;
  bool muted = false;

  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  RTCDataChannel? _dataChannel;
  RTCVideoRenderer? _remoteRenderer;
  bool _disposed = false;

  bool get active => state == VoiceSessionState.requestingMicrophone ||
      state == VoiceSessionState.negotiating ||
      state == VoiceSessionState.connected;

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

      final dataInit = RTCDataChannelInit()..ordered = true;
      final dataChannel = await peer.createDataChannel('oai-events', dataInit);
      _dataChannel = dataChannel;
      dataChannel.onMessage = _onDataMessage;

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
      final decoded = jsonDecode(text);
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
    final item = event['item'];
    if (item is Map) {
      final content = item['content'];
      if (content is List) {
        final parts = <String>[];
        for (final entry in content) {
          if (entry is Map) {
            final transcript = entry['transcript'] ?? entry['text'];
            if (transcript is String && transcript.trim().isNotEmpty) {
              parts.add(transcript.trim());
            }
          }
        }
        if (parts.isNotEmpty) {
          return parts.join('\n');
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
      // Continue rather than failing a voice call solely on a missing complete
      // callback; ChatGPT's SDP answer will reject an unusable offer cleanly.
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
