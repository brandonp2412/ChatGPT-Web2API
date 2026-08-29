import 'package:flutter/material.dart';

import '../state/chat_controller.dart';
import 'voice_session.dart';

class VoiceOverlay extends StatelessWidget {
  const VoiceOverlay({
    required this.controller,
    required this.child,
    super.key,
  });

  final ChatController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        child,
        Positioned(
          right: 18,
          bottom: 88,
          child: AnimatedBuilder(
            animation: controller,
            builder: (BuildContext context, Widget? _) {
              return FloatingActionButton.small(
                heroTag: 'chatgpt-voice',
                tooltip: controller.connected
                    ? 'Voice'
                    : 'Connect the bridge to use Voice',
                onPressed: !controller.connected || controller.sending
                    ? null
                    : () => _openVoice(context),
                child: const Icon(Icons.graphic_eq),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openVoice(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => VoiceDialog(controller: controller),
    );
  }
}

class VoiceDialog extends StatefulWidget {
  const VoiceDialog({required this.controller, super.key});

  final ChatController controller;

  @override
  State<VoiceDialog> createState() => _VoiceDialogState();
}

class _VoiceDialogState extends State<VoiceDialog> {
  late VoiceSession _session;
  String _voice = 'cove';

  @override
  void initState() {
    super.initState();
    _session = _newSession();
    _session.addListener(_voiceChanged);
  }

  VoiceSession _newSession() {
    return VoiceSession(
      settings: widget.controller.settings,
      conversationId: widget.controller.activeConversation?.id,
      projectId: widget.controller.activeProject?.id,
      voice: _voice,
    );
  }

  void _voiceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _replaceSession() async {
    _session.removeListener(_voiceChanged);
    await _session.stop();
    _session.dispose();
    _session = _newSession();
    _session.addListener(_voiceChanged);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _session.removeListener(_voiceChanged);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    final busy =
        state == VoiceSessionState.requestingMicrophone ||
        state == VoiceSessionState.negotiating;
    final connected = state == VoiceSessionState.connected;
    final failed = state == VoiceSessionState.failed;
    final contextLabel =
        widget.controller.activeConversation?.title ??
        widget.controller.activeProject?.name ??
        'New chat';

    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Icon(Icons.graphic_eq),
          const SizedBox(width: 10),
          const Expanded(child: Text('Voice')),
          IconButton(
            tooltip: 'Close',
            onPressed: busy ? null : _close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              contextLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 22),
            _statusGraphic(state),
            const SizedBox(height: 18),
            Text(
              _statusText(state),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_session.errorMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _session.errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_session.transcript != null) ...<Widget>[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 130),
                child: SingleChildScrollView(
                  child: Text(
                    _session.transcript!,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
            if (!connected && !busy) ...<Widget>[
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: _voice,
                decoration: const InputDecoration(
                  labelText: 'Voice',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: VoiceSession.supportedVoices
                    .map(
                      (String voice) => DropdownMenuItem<String>(
                        value: voice,
                        child: Text(_title(voice)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (String? value) async {
                  if (value == null || value == _voice) {
                    return;
                  }
                  _voice = value;
                  await _replaceSession();
                },
              ),
            ],
            const SizedBox(height: 22),
            if (connected)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton.filledTonal(
                    tooltip: _session.muted ? 'Unmute' : 'Mute',
                    onPressed: () => _session.setMuted(!_session.muted),
                    icon: Icon(_session.muted ? Icons.mic_off : Icons.mic),
                  ),
                  const SizedBox(width: 18),
                  IconButton.filled(
                    tooltip: 'End voice',
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    onPressed: _end,
                    icon: const Icon(Icons.call_end),
                  ),
                ],
              )
            else if (busy)
              const CircularProgressIndicator()
            else
              FilledButton.icon(
                onPressed: _session.start,
                icon: Icon(failed ? Icons.refresh : Icons.mic),
                label: Text(failed ? 'Retry' : 'Start voice'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusGraphic(VoiceSessionState state) {
    if (state == VoiceSessionState.connected) {
      return const Icon(Icons.graphic_eq, size: 58);
    }
    if (state == VoiceSessionState.failed) {
      return Icon(
        Icons.error_outline,
        size: 52,
        color: Theme.of(context).colorScheme.error,
      );
    }
    if (state == VoiceSessionState.requestingMicrophone ||
        state == VoiceSessionState.negotiating) {
      return const Icon(Icons.graphic_eq, size: 52);
    }
    return const Icon(Icons.mic_none, size: 52);
  }

  String _statusText(VoiceSessionState state) {
    return switch (state) {
      VoiceSessionState.idle => 'Ready',
      VoiceSessionState.requestingMicrophone => 'Opening microphone…',
      VoiceSessionState.negotiating => 'Connecting…',
      VoiceSessionState.connected => 'Listening',
      VoiceSessionState.failed => 'Voice unavailable',
      VoiceSessionState.ended => 'Voice ended',
    };
  }

  Future<void> _end() async {
    await _session.stop();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _close() async {
    await _session.stop();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  static String _title(String value) {
    if (value.isEmpty) {
      return value;
    }
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }
}
