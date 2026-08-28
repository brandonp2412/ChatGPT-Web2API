import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/bridge_client.dart';
import '../model/chat_models.dart';
import '../state/chat_controller.dart';
import 'message_view.dart';

class ChatHome extends StatefulWidget {
  const ChatHome({required this.controller, super.key});

  final ChatController controller;

  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> {
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final ScrollController _messages = ScrollController();

  ChatController get controller => widget.controller;

  @override
  void dispose() {
    _composer.dispose();
    _search.dispose();
    _messages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        if (!controller.initialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (controller.sending) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        }
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final wide = constraints.maxWidth >= 900;
            final sidebar = _Sidebar(
              controller: controller,
              searchController: _search,
            );
            return Scaffold(
              drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
              appBar: AppBar(
                title: Text(controller.activeConversation?.title ?? 'New chat'),
                actions: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Tooltip(
                      message: controller.connected ? 'Bridge connected' : 'Bridge disconnected',
                      child: Icon(
                        controller.connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                        size: 20,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: controller.connecting ? null : () => controller.connect(),
                    icon: controller.connecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: () => _showSettings(context),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
              body: Row(
                children: <Widget>[
                  if (wide)
                    SizedBox(
                      width: 300,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(color: Theme.of(context).dividerColor),
                          ),
                        ),
                        child: sidebar,
                      ),
                    ),
                  Expanded(child: _conversationPane(context)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _conversationPane(BuildContext context) {
    final error = controller.errorMessage;
    return Column(
      children: <Widget>[
        if (error != null)
          MaterialBanner(
            content: Text(error),
            actions: <Widget>[
              TextButton(
                onPressed: () => controller.connect(),
                child: const Text('Retry'),
              ),
            ],
          ),
        _ComposerControls(controller: controller),
        const Divider(height: 1),
        Expanded(
          child: controller.loadingConversation
              ? const Center(child: CircularProgressIndicator())
              : _messageList(),
        ),
        _pendingAttachments(),
        _composerBox(context),
      ],
    );
  }

  Widget _messageList() {
    final messageCount = controller.visibleMessages.length;
    final reports = controller.activeConversation?.researchReports ?? const <ResearchReport>[];
    final total = messageCount + reports.length;
    if (total == 0) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Start a chat. The app uses your logged-in ChatGPT subscription through your bridge.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _messages,
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: total,
      itemBuilder: (BuildContext context, int index) {
        if (index < messageCount) {
          final message = controller.visibleMessages[index];
          return MessageView(
            key: ValueKey<String>('message-${message.id}-$index'),
            message: message,
            conversation: controller.activeConversation,
            onSelectBranch: controller.selectBranch,
          );
        }
        final report = reports[index - messageCount];
        return ResearchReportView(report: report);
      },
    );
  }

  Widget _pendingAttachments() {
    if (controller.pendingAttachments.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: controller.pendingAttachments.map((UploadedAttachment item) {
            return InputChip(
              avatar: const Icon(Icons.attach_file, size: 16),
              label: Text(item.name),
              onDeleted: controller.sending
                  ? null
                  : () => controller.removePendingAttachment(item.id),
            );
          }).toList(growable: false),
        ),
      ),
    );
  }

  Widget _composerBox(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    tooltip: 'Attach file',
                    onPressed: controller.sending ? null : _pickFiles,
                    icon: const Icon(Icons.add),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 8,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Message ChatGPT',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 14),
                      ),
                      onSubmitted: (String value) {
                        if (!HardwareKeyboard.instance.isShiftPressed) {
                          _submit();
                        }
                      },
                    ),
                  ),
                  if (controller.sending)
                    IconButton.filled(
                      tooltip: 'Stop',
                      onPressed: controller.stopGeneration,
                      icon: const Icon(Icons.stop, size: 18),
                    )
                  else
                    IconButton.filled(
                      tooltip: 'Send',
                      onPressed: _submit,
                      icon: const Icon(Icons.arrow_upward, size: 19),
                    ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null) {
      return;
    }
    for (final file in result.files) {
      final path = file.path;
      if (path != null && path.isNotEmpty) {
        await controller.addAttachment(File(path));
      }
    }
  }

  void _submit() {
    final text = _composer.text;
    if (text.trim().isEmpty && controller.pendingAttachments.isEmpty) {
      return;
    }
    _composer.clear();
    controller.send(text);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (!_messages.hasClients) {
      return;
    }
    _messages.animateTo(
      _messages.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    final url = TextEditingController(text: controller.settings.baseUrl);
    final key = TextEditingController(text: controller.settings.apiKey);
    String? validation;
    final next = await showDialog<BridgeSettings>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: const Text('Bridge settings'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: url,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: 'Bridge URL',
                        hintText: 'https://bridge.example.com',
                        errorText: validation,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: key,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Bridge API key',
                        helperText: 'Stored in OS secure storage. This is not an OpenAI key.',
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final error = BridgeSettings.validateBaseUrl(url.text);
                    if (error != null) {
                      setDialogState(() => validation = error);
                      return;
                    }
                    Navigator.pop(
                      context,
                      BridgeSettings(baseUrl: url.text, apiKey: key.text),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    url.dispose();
    key.dispose();
    if (next != null) {
      await controller.saveSettings(next);
    }
  }
}

class _ComposerControls extends StatelessWidget {
  const _ComposerControls({required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    final modes = controller.availableModes;
    final selectedMode = modes.contains(controller.selectedMode)
        ? controller.selectedMode
        : 'normal';
    final reasoningItems = <String>['auto', ...controller.reasoningLevels];
    final selectedReasoning = controller.selectedReasoningLevel != null &&
            reasoningItems.contains(controller.selectedReasoningLevel)
        ? controller.selectedReasoningLevel!
        : 'auto';
    final models = controller.models.isEmpty ? const <String>['auto'] : controller.models;
    final selectedModel = models.contains(controller.selectedModel)
        ? controller.selectedModel
        : models.first;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          _CompactDropdown(
            tooltip: 'Model',
            value: selectedModel,
            values: models,
            label: _modelLabel,
            onChanged: controller.sending ? null : controller.setModel,
          ),
          const SizedBox(width: 6),
          _CompactDropdown(
            tooltip: 'Reasoning',
            value: selectedReasoning,
            values: reasoningItems,
            label: _reasoningLabel,
            onChanged: controller.sending
                ? null
                : (String value) => controller.setReasoningLevel(value),
          ),
          const SizedBox(width: 6),
          _CompactDropdown(
            tooltip: 'Tool',
            value: selectedMode,
            values: modes,
            label: _modeLabel,
            onChanged: controller.sending ? null : controller.setMode,
          ),
        ],
      ),
    );
  }

  static String _modelLabel(String value) => value == 'auto' ? 'Auto' : value;

  static String _reasoningLabel(String value) {
    if (value == 'auto') {
      return 'Reasoning: Auto';
    }
    return 'Reasoning: ${_title(value)}';
  }

  static String _modeLabel(String value) {
    return switch (value) {
      'normal' => 'Chat',
      'search' => 'Search',
      'image' => 'Create image',
      'deep_research' => 'Deep research',
      'study' => 'Study',
      _ => _title(value),
    };
  }

  static String _title(String value) {
    return value
        .replaceAll('_', ' ')
        .split(' ')
        .where((String part) => part.isNotEmpty)
        .map((String part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }
}

class _CompactDropdown extends StatelessWidget {
  const _CompactDropdown({
    required this.tooltip,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final String tooltip;
  final String value;
  final List<String> values;
  final String Function(String value) label;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          items: values
              .map(
                (String item) => DropdownMenuItem<String>(
                  value: item,
                  child: Text(label(item)),
                ),
              )
              .toList(growable: false),
          onChanged: onChanged == null
              ? null
              : (String? next) {
                  if (next != null) {
                    onChanged!(next);
                  }
                },
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller, required this.searchController});

  final ChatController controller;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () {
                controller.newChat();
                if (Scaffold.maybeOf(context)?.isDrawerOpen == true) {
                  Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('New chat'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search chats',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: controller.searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        searchController.clear();
                        controller.search('');
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onSubmitted: controller.search,
          ),
        ),
        Expanded(
          child: controller.conversations.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No chats loaded', textAlign: TextAlign.center),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  itemCount: controller.conversations.length,
                  itemBuilder: (BuildContext context, int index) {
                    final item = controller.conversations[index];
                    final selected = item.id == controller.activeConversation?.id;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        controller.selectConversation(item.id);
                        if (Scaffold.maybeOf(context)?.isDrawerOpen == true) {
                          Navigator.pop(context);
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
