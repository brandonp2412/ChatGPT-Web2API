import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/chat_models.dart';

class MessageView extends StatelessWidget {
  const MessageView({
    required this.message,
    required this.conversation,
    required this.onSelectBranch,
    required this.onRegenerate,
    required this.onEdit,
    required this.onBranchInNewChat,
    super.key,
  });

  final ChatMessage message;
  final ChatConversation? conversation;
  final ValueChanged<String> onSelectBranch;
  final ValueChanged<ChatMessage> onRegenerate;
  final Future<void> Function(ChatMessage message, String replacement) onEdit;
  final ValueChanged<ChatMessage> onBranchInNewChat;

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
            MarkdownBody(
              data: message.text,
              selectable: true,
              onTapLink: (String text, String? href, String title) {
                if (href == null) {
                  return;
                }
                final uri = Uri.tryParse(href);
                if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          if (isStreaming) ...<Widget>[
            const SizedBox(height: 8),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          if (message.assets.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: message.assets.map((ChatAsset asset) {
                return Chip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(asset.fileName ?? asset.mimeType ?? 'Attachment'),
                  visualDensity: VisualDensity.compact,
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

  Widget _messageActions(BuildContext context, BranchPosition? branch) {
    final isUser = message.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (isUser)
            IconButton(
              tooltip: 'Edit message',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => _showEditDialog(context),
              icon: const Icon(Icons.edit_outlined),
            )
          else
            IconButton(
              tooltip: 'Regenerate',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => onRegenerate(message),
              icon: const Icon(Icons.refresh),
            ),
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

  BranchPosition? _branchPosition() {
    final source = conversation;
    if (source == null) {
      return null;
    }
    return source.branchPositionFor(message);
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
