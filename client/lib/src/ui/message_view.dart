import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/bridge_client.dart';
import '../model/chat_models.dart';
import 'bridge_asset.dart';

class MessageView extends StatelessWidget {
  const MessageView({
    required this.message,
    required this.conversation,
    required this.settings,
    required this.onSelectBranch,
    required this.onRegenerate,
    required this.onEdit,
    required this.onBranchInNewChat,
    required this.onBlockAction,
    required this.onFeedback,
    super.key,
  });

  final ChatMessage message;
  final ChatConversation? conversation;
  final BridgeSettings settings;
  final ValueChanged<String> onSelectBranch;
  final ValueChanged<ChatMessage> onRegenerate;
  final Future<void> Function(ChatMessage message, String replacement) onEdit;
  final ValueChanged<ChatMessage> onBranchInNewChat;
  final Future<void> Function(ChatMessage message, String action, String? text)
      onBlockAction;
  final Future<void> Function(ChatMessage message, String rating) onFeedback;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isStreaming = message.status == 'in_progress';
    final theme = Theme.of(context);
    final branch = _branchPosition();
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          if (isUser)
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: SelectableText(message.text),
              ),
            )
          else
            _assistantBody(context),
          if (isStreaming) ...<Widget>[
            const SizedBox(height: 8),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          if (!isStreaming) _messageActions(context, branch),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: content,
      ),
    );
  }

  Widget _assistantBody(BuildContext context) {
    final extraBlocks = message.blocks.where((Map<String, dynamic> block) {
      final type = block['type']?.toString();
      return type != 'text' &&
          type != 'reasoning_recap' &&
          type != 'citations' &&
          type != 'image' &&
          type != 'file' &&
          type != 'editable_block';
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (message.text.isNotEmpty)
          MarkdownBody(
            data: message.text,
            selectable: true,
            onTapLink: (String text, String? href, String title) {
              if (href != null) {
                _launchSafe(href);
              }
            },
          ),
        ...extraBlocks.map((Map<String, dynamic> block) => _block(context, block)),
        if (message.assets.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: message.assets.map((ChatAsset asset) {
              if (asset.isImage) {
                return BridgeAssetImage(
                  settings: settings,
                  asset: asset,
                  conversationId: conversation?.id,
                );
              }
              return BridgeAssetDownloadButton(
                settings: settings,
                asset: asset,
                conversationId: conversation?.id,
              );
            }).toList(growable: false),
          ),
        ],
        if (message.citations.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: message.citations.asMap().entries.map((entry) {
              final citation = entry.value;
              return ActionChip(
                avatar: const Icon(Icons.link, size: 15),
                label: Text(
                  citation.title?.trim().isNotEmpty == true
                      ? citation.title!
                      : 'Source ${entry.key + 1}',
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: citation.url == null
                    ? null
                    : () => _launchSafe(citation.url!),
              );
            }).toList(growable: false),
          ),
        ],
        if (_editableBlock() case final editable?) ...<Widget>[
          const SizedBox(height: 8),
          _blockControls(context, editable),
        ],
      ],
    );
  }

  Widget _block(BuildContext context, Map<String, dynamic> block) {
    final type = block['type']?.toString() ?? '';
    switch (type) {
      case 'code':
        final code = block['code']?.toString() ?? '';
        if (code.isEmpty) {
          return const SizedBox.shrink();
        }
        final language = block['language']?.toString();
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          language?.isNotEmpty == true ? language! : 'Code',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy code',
                        visualDensity: VisualDensity.compact,
                        iconSize: 17,
                        onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                        icon: const Icon(Icons.copy_outlined),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      code,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      case 'execution_output':
        final text = block['text']?.toString() ?? '';
        if (text.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        );
      case 'quote':
        final text = block['text']?.toString() ?? '';
        if (text.isEmpty) {
          return const SizedBox.shrink();
        }
        final url = block['url']?.toString();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: InkWell(
            onTap: url?.isNotEmpty == true ? () => _launchSafe(url!) : null,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    width: 3,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              child: SelectableText(text),
            ),
          ),
        );
      case 'tool':
      case 'research':
        final name = block['name']?.toString() ??
            (type == 'research' ? 'Deep Research' : 'Tool');
        final status = block['status']?.toString();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Chip(
            avatar: Icon(
              type == 'research' ? Icons.travel_explore : Icons.build_outlined,
              size: 16,
            ),
            label: Text(status?.isNotEmpty == true ? '$name · $status' : name),
            visualDensity: VisualDensity.compact,
          ),
        );
      case 'reasoning_status':
        return const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Reasoning', style: TextStyle(fontStyle: FontStyle.italic)),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Map<String, dynamic>? _editableBlock() {
    for (final block in message.blocks) {
      if (block['type']?.toString() == 'editable_block') {
        return block;
      }
    }
    return null;
  }

  Widget _blockControls(
    BuildContext context,
    Map<String, dynamic> editable,
  ) {
    final kind = editable['block_kind']?.toString() ?? '';
    final code = _firstCodeBlockText();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        ActionChip(
          avatar: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('Edit'),
          onPressed: () => _showBlockEditDialog(context, code),
        ),
        if (kind == 'code' || code.isNotEmpty)
          ActionChip(
            avatar: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Run'),
            onPressed: () => onBlockAction(message, 'run', null),
          ),
        ActionChip(
          avatar: const Icon(Icons.visibility_outlined, size: 16),
          label: const Text('Preview'),
          onPressed: () => onBlockAction(message, 'preview', null),
        ),
        ActionChip(
          avatar: const Icon(Icons.open_in_full, size: 16),
          label: const Text('Open'),
          onPressed: () => onBlockAction(message, 'open', null),
        ),
      ],
    );
  }

  String _firstCodeBlockText() {
    for (final block in message.blocks) {
      if (block['type']?.toString() == 'code') {
        return block['code']?.toString() ?? '';
      }
    }
    return '';
  }

  Widget _messageActions(BuildContext context, BranchPosition? branch) {
    final isUser = message.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: message.text.isEmpty
                ? null
                : () => Clipboard.setData(ClipboardData(text: message.text)),
            icon: const Icon(Icons.copy_outlined),
          ),
          if (isUser)
            IconButton(
              tooltip: 'Edit message',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => _showEditDialog(context),
              icon: const Icon(Icons.edit_outlined),
            )
          else ...<Widget>[
            IconButton(
              tooltip: 'Good response',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => onFeedback(message, 'thumbs_up'),
              icon: const Icon(Icons.thumb_up_alt_outlined),
            ),
            IconButton(
              tooltip: 'Bad response',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => onFeedback(message, 'thumbs_down'),
              icon: const Icon(Icons.thumb_down_alt_outlined),
            ),
            IconButton(
              tooltip: 'Regenerate',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => onRegenerate(message),
              icon: const Icon(Icons.refresh),
            ),
          ],
          IconButton(
            tooltip: 'Branch in new chat',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: () => onBranchInNewChat(message),
            icon: const Icon(Icons.call_split_outlined),
          ),
          if (!isUser && branch != null) ...<Widget>[
            IconButton(
              tooltip: 'Previous response',
              visualDensity: VisualDensity.compact,
              onPressed: branch.hasPrevious && branch.previousNode != null
                  ? () => onSelectBranch(branch.previousNode!)
                  : null,
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            Text(
              '${branch.index + 1}/${branch.siblings.length}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            IconButton(
              tooltip: 'Next response',
              visualDensity: VisualDensity.compact,
              onPressed: branch.hasNext && branch.nextNode != null
                  ? () => onSelectBranch(branch.nextNode!)
                  : null,
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final controller = TextEditingController(text: message.text);
    final replacement = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Edit message'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 12,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (replacement != null && replacement.trim().isNotEmpty) {
      await onEdit(message, replacement);
    }
  }

  Future<void> _showBlockEditDialog(BuildContext context, String initial) async {
    final controller = TextEditingController(text: initial);
    final replacement = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Edit block'),
        content: SizedBox(
          width: 640,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 24,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (replacement != null) {
      await onBlockAction(message, 'edit', replacement);
    }
  }

  BranchPosition? _branchPosition() {
    final source = conversation;
    if (source == null) {
      return null;
    }
    return source.branchPositionFor(message);
  }

  Future<void> _launchSafe(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class ResearchReportView extends StatelessWidget {
  const ResearchReportView({required this.report, super.key});

  final ResearchReport report;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.travel_explore, size: 18),
                    const SizedBox(width: 8),
                    Text('Deep Research', style: Theme.of(context).textTheme.titleSmall),
                    if (report.status != null) ...<Widget>[
                      const Spacer(),
                      Text(report.status!, style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                MarkdownBody(data: report.text, selectable: true),
                if (report.citations.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: report.citations.asMap().entries.map((entry) {
                      final citation = entry.value;
                      return ActionChip(
                        label: Text(citation.title ?? 'Source ${entry.key + 1}'),
                        onPressed: citation.url == null
                            ? null
                            : () {
                                final uri = Uri.tryParse(citation.url!);
                                if (uri != null &&
                                    (uri.scheme == 'https' || uri.scheme == 'http')) {
                                  launchUrl(uri, mode: LaunchMode.externalApplication);
                                }
                              },
                      );
                    }).toList(growable: false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
