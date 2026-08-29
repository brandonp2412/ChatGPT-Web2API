import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/bridge_client.dart';
import '../model/chat_models.dart';

class BridgeAssetImage extends StatefulWidget {
  const BridgeAssetImage({
    required this.settings,
    required this.asset,
    this.conversationId,
    super.key,
  });

  final BridgeSettings settings;
  final ChatAsset asset;
  final String? conversationId;

  @override
  State<BridgeAssetImage> createState() => _BridgeAssetImageState();
}

class _BridgeAssetImageState extends State<BridgeAssetImage> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant BridgeAssetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.pointer != widget.asset.pointer ||
        oldWidget.asset.url != widget.asset.url ||
        oldWidget.conversationId != widget.conversationId ||
        oldWidget.settings.baseUrl != widget.settings.baseUrl ||
        oldWidget.settings.apiKey != widget.settings.apiKey) {
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() {
    return _fetchAssetBytes(
      settings: widget.settings,
      asset: widget.asset,
      conversationId: widget.conversationId,
      accept: 'image/*,*/*;q=0.8',
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 180,
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || snapshot.hasError) {
          return Container(
            constraints: const BoxConstraints(minWidth: 180, minHeight: 80),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.broken_image_outlined),
                SizedBox(width: 8),
                Text('Image unavailable'),
              ],
            ),
          );
        }
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showFullImage(context, bytes),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showFullImage(BuildContext context, Uint8List bytes) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog.fullscreen(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BridgeAssetDownloadButton extends StatefulWidget {
  const BridgeAssetDownloadButton({
    required this.settings,
    required this.asset,
    this.conversationId,
    super.key,
  });

  final BridgeSettings settings;
  final ChatAsset asset;
  final String? conversationId;

  @override
  State<BridgeAssetDownloadButton> createState() =>
      _BridgeAssetDownloadButtonState();
}

class _BridgeAssetDownloadButtonState extends State<BridgeAssetDownloadButton> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final name = widget.asset.fileName ?? 'Attachment';
    return ActionChip(
      avatar: _saving
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined, size: 16),
      label: Text(name),
      onPressed: _saving ? null : _save,
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final bytes = await _fetchAssetBytes(
        settings: widget.settings,
        asset: widget.asset,
        conversationId: widget.conversationId,
      );
      if (!mounted) {
        return;
      }
      final suggested = _safeFileName(widget.asset.fileName ?? 'attachment');
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save attachment',
        fileName: suggested,
        bytes: bytes,
      );
      if (path == null) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Attachment saved')));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save attachment: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

Future<Uint8List> _fetchAssetBytes({
  required BridgeSettings settings,
  required ChatAsset asset,
  String? conversationId,
  String accept = '*/*',
}) async {
  final resolved = _assetUri(
    settings: settings,
    asset: asset,
    conversationId: conversationId,
  );
  final bridge = settings.baseUri;
  final sameBridge =
      resolved.scheme == bridge.scheme &&
      resolved.host == bridge.host &&
      resolved.port == bridge.port;
  final response = await http.get(
    resolved,
    headers: <String, String>{
      'Accept': accept,
      if (sameBridge && settings.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${settings.apiKey.trim()}',
    },
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw BridgeException(
      'Asset load failed (HTTP ${response.statusCode})',
      statusCode: response.statusCode,
    );
  }
  return response.bodyBytes;
}

Uri _assetUri({
  required BridgeSettings settings,
  required ChatAsset asset,
  String? conversationId,
}) {
  final pointer = asset.pointer;
  if (pointer != null && pointer.isNotEmpty) {
    final base = settings.baseUri;
    final segments = <String>[
      ...base.pathSegments.where((String part) => part.isNotEmpty),
      'v1',
      'assets',
      pointer,
    ];
    return base.replace(
      pathSegments: segments,
      queryParameters: <String, String>{
        if (conversationId?.isNotEmpty == true)
          'conversation_id': conversationId!,
        'inline': '1',
      },
    );
  }
  final direct = asset.url;
  final uri = direct == null ? null : Uri.tryParse(direct);
  if (uri == null || !_isAllowedDirectAssetUri(uri)) {
    throw const BridgeException('Asset has no safe download location');
  }
  return uri;
}

bool _isAllowedDirectAssetUri(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'oaidalleapiprodscus.blob.core.windows.net') {
    return true;
  }
  const suffixes = <String>[
    'oaiusercontent.com',
    'oaistatic.com',
    'chatgpt.com',
    'openai.com',
  ];
  return suffixes.any(
    (String suffix) => host == suffix || host.endsWith('.$suffix'),
  );
}

String _safeFileName(String value) {
  final clean = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_')
      .trim();
  return clean.isEmpty ? 'attachment' : clean;
}
