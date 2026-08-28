import 'dart:typed_data';

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

  Future<Uint8List> _load() async {
    final uri = _assetUri();
    final response = await http.get(
      uri,
      headers: <String, String>{
        'Accept': 'image/*,*/*;q=0.8',
        if (widget.settings.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${widget.settings.apiKey.trim()}',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BridgeException(
        'Image load failed (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Uri _assetUri() {
    final pointer = widget.asset.pointer;
    if (pointer != null && pointer.isNotEmpty) {
      final base = widget.settings.baseUri;
      final segments = <String>[
        ...base.pathSegments.where((String part) => part.isNotEmpty),
        'v1',
        'assets',
        pointer,
      ];
      return base.replace(
        pathSegments: segments,
        queryParameters: <String, String>{
          if (widget.conversationId?.isNotEmpty == true)
            'conversation_id': widget.conversationId!,
          'inline': '1',
        },
      );
    }
    final direct = widget.asset.url;
    final uri = direct == null ? null : Uri.tryParse(direct);
    if (uri == null || uri.scheme != 'https') {
      throw const BridgeException('Image asset has no safe download location');
    }
    return uri;
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
        final image = Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        );
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showFullImage(context, bytes),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
              child: image,
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
