import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/bridge_client.dart';
import '../model/account_models.dart';
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
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
              onCreateProject: _createProject,
            );
            return Scaffold(
              drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
              appBar: AppBar(
                title: Text(_pageTitle()),
                actions: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Tooltip(
                      message: controller.connected
                          ? 'Bridge connected'
                          : 'Bridge disconnected',
                      child: Icon(
                        controller.connected
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
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
                  if (controller.activeProject != null)
                    IconButton(
                      tooltip: 'Project settings',
                      onPressed: controller.parityActionBusy
                          ? null
                          : () => _showProjectSettings(context),
                      icon: const Icon(Icons.folder_open_outlined),
                    ),
                  if (controller.activeConversation != null)
                    PopupMenuButton<_ConversationMenuAction>(
                      tooltip: 'Chat actions',
                      onSelected: _handleConversationMenu,
                      itemBuilder: (BuildContext context) => <PopupMenuEntry<_ConversationMenuAction>>[
                        const PopupMenuItem(
                          value: _ConversationMenuAction.rename,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.edit_outlined),
                            title: Text('Rename'),
                          ),
                        ),
                        PopupMenuItem(
                          value: _ConversationMenuAction.pin,
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              controller.activeConversationPinned
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined,
                            ),
                            title: Text(
                              controller.activeConversationPinned ? 'Unpin' : 'Pin',
                            ),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ConversationMenuAction.share,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.ios_share_outlined),
                            title: Text('Share'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ConversationMenuAction.archive,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.archive_outlined),
                            title: Text('Archive'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ConversationMenuAction.delete,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.delete_outline),
                            title: Text('Delete'),
                          ),
                        ),
                      ],
                    ),
                  IconButton(
                    tooltip: 'Memory',
                    onPressed: controller.connected ? () => _showMemories(context) : null,
                    icon: const Icon(Icons.psychology_outlined),
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

  String _pageTitle() {
    final active = controller.activeConversation;
    if (active != null) {
      return active.title;
    }
    if (controller.activeProject != null) {
      return controller.activeProject!.name;
    }
    if (controller.activeGpt != null) {
      return controller.activeGpt!.name;
    }
    return controller.temporaryChat ? 'Temporary Chat' : 'New chat';
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
        if (controller.interactiveActions.isNotEmpty)
          _InteractiveActions(controller: controller),
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
    final reports = controller.activeConversation?.researchReports ??
        const <ResearchReport>[];
    final total = messageCount + reports.length;
    if (total == 0) {
      final contextLabel = controller.activeProject != null
          ? ' in ${controller.activeProject!.name}'
          : controller.activeGpt != null
              ? ' with ${controller.activeGpt!.name}'
              : '';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Start a chat$contextLabel. Your ChatGPT subscription stays on the bridge.',
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
            settings: controller.settings,
            onSelectBranch: controller.selectBranch,
            onRegenerate: controller.regenerate,
            onEdit: controller.editMessage,
            onBranchInNewChat: controller.branchInNewChat,
            onBlockAction: (
              ChatMessage message,
              String action,
              String? text,
            ) =>
                controller.runBlockAction(message, action, text: text),
            onFeedback: controller.sendFeedback,
          );
        }
        final report = reports[index - messageCount];
        return ResearchReportView(report: report);
      },
    );
  }

  Widget _pendingAttachments() {
    if (controller.pendingAttachments.isEmpty &&
        controller.pendingLibraryFiles.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            ...controller.pendingAttachments.map((UploadedAttachment item) {
              return InputChip(
                avatar: const Icon(Icons.attach_file, size: 16),
                label: Text(item.name),
                onDeleted: controller.sending
                    ? null
                    : () => controller.removePendingAttachment(item.id),
              );
            }),
            ...controller.pendingLibraryFiles.map((String name) {
              return InputChip(
                avatar: const Icon(Icons.folder_copy_outlined, size: 16),
                label: Text(name),
                onDeleted: controller.sending
                    ? null
                    : () => controller.removeLibraryFile(name),
              );
            }),
          ],
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
                  PopupMenuButton<_AttachmentAction>(
                    tooltip: 'Add',
                    enabled: !controller.sending,
                    onSelected: (action) {
                      if (action == _AttachmentAction.upload) {
                        _pickFiles();
                      } else {
                        _pickLibraryFiles();
                      }
                    },
                    itemBuilder: (BuildContext context) =>
                        const <PopupMenuEntry<_AttachmentAction>>[
                      PopupMenuItem(
                        value: _AttachmentAction.upload,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.upload_file_outlined),
                          title: Text('Upload files'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _AttachmentAction.library,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.folder_copy_outlined),
                          title: Text('Add from Library'),
                        ),
                      ),
                    ],
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

  Future<void> _pickLibraryFiles() async {
    final items = await controller.loadLibrary();
    if (!mounted || items.isEmpty) {
      return;
    }
    final selected = <String>{...controller.pendingLibraryFiles};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: const Text('Add from Library'),
              content: SizedBox(
                width: 520,
                height: 420,
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int index) {
                    final item = items[index];
                    return CheckboxListTile(
                      value: selected.contains(item.name),
                      title: Text(item.name),
                      subtitle: item.detail == null ? null : Text(item.detail!),
                      onChanged: (bool? value) {
                        setDialogState(() {
                          if (value == true) {
                            selected.add(item.name);
                          } else {
                            selected.remove(item.name);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selected),
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result != null) {
      controller.addLibraryFiles(result);
    }
  }

  void _submit() {
    final text = _composer.text;
    if (text.trim().isEmpty &&
        controller.pendingAttachments.isEmpty &&
        controller.pendingLibraryFiles.isEmpty) {
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

  Future<void> _handleConversationMenu(_ConversationMenuAction action) async {
    switch (action) {
      case _ConversationMenuAction.rename:
        await _renameChat();
      case _ConversationMenuAction.pin:
        await controller.toggleActivePin();
      case _ConversationMenuAction.share:
        await _shareChat();
      case _ConversationMenuAction.archive:
        await _confirmConversationMutation(delete: false);
      case _ConversationMenuAction.delete:
        await _confirmConversationMutation(delete: true);
    }
  }

  Future<void> _renameChat() async {
    final active = controller.activeConversation;
    if (active == null) {
      return;
    }
    final text = TextEditingController(text: active.title);
    final result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(controller: text, autofocus: true),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    text.dispose();
    if (result != null) {
      await controller.renameActiveConversation(result);
    }
  }

  Future<void> _shareChat() async {
    final share = await controller.shareActiveConversation();
    if (!mounted || share == null) {
      return;
    }
    final display = share.url ?? share.id;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Share chat'),
        content: SizedBox(
          width: 520,
          child: SelectableText(display),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: display)),
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy'),
          ),
          TextButton(
            onPressed: () async {
              await controller.deleteActiveShare();
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('Revoke'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmConversationMutation({required bool delete}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(delete ? 'Delete chat?' : 'Archive chat?'),
        content: Text(
          delete
              ? 'This removes the conversation from ChatGPT.'
              : 'This archives the conversation in ChatGPT.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(delete ? 'Delete' : 'Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (delete) {
      await controller.deleteActiveConversation();
    } else {
      await controller.archiveActiveConversation();
    }
  }

  Future<void> _showMemories(BuildContext context) async {
    await controller.loadMemories();
    if (!mounted) {
      return;
    }
    final input = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          final items = controller.memoryItems;
          return AlertDialog(
            title: const Text('Memory'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: input,
                          decoration: const InputDecoration(
                            labelText: 'Add a memory',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Add memory',
                        onPressed: () async {
                          await controller.createMemory(input.text);
                          input.clear();
                          setDialogState(() {});
                        },
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: items.isEmpty
                        ? const Center(child: Text('No saved memories'))
                        : ListView.builder(
                            itemCount: items.length,
                            itemBuilder: (BuildContext context, int index) {
                              final item = items[index];
                              return ListTile(
                                title: Text(item.content),
                                trailing: item.id.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Delete memory',
                                        onPressed: () async {
                                          await controller.deleteMemory(item.id);
                                          setDialogState(() {});
                                        },
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
    input.dispose();
  }

  Future<void> _createProject() async {
    final name = TextEditingController();
    final instructions = TextEditingController();
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('New project'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: instructions,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Instructions',
                  alignLabelWithHint: true,
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
            onPressed: () => Navigator.pop(
              context,
              (name.text.trim(), instructions.text.trim()),
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    name.dispose();
    instructions.dispose();
    if (result == null || result.$1.isEmpty) {
      return;
    }
    final project = await controller.createProject(
      name: result.$1,
      instructions: result.$2,
    );
    if (project != null) {
      await controller.openProject(project);
    }
  }

  Future<void> _showProjectSettings(BuildContext context) async {
    final project = controller.activeProject;
    if (project == null) {
      return;
    }
    await controller.loadActiveProjectFiles(silent: true);
    if (!mounted) {
      return;
    }
    final instructions = TextEditingController(text: project.instructions ?? '');
    final action = await showDialog<_ProjectDialogAction>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(project.name),
        content: SizedBox(
          width: 600,
          height: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: instructions,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Project instructions',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 18),
              Text('Files', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Expanded(
                child: controller.activeProjectFiles.isEmpty
                    ? const Center(child: Text('No project files'))
                    : ListView.builder(
                        itemCount: controller.activeProjectFiles.length,
                        itemBuilder: (BuildContext context, int index) {
                          final file = controller.activeProjectFiles[index];
                          return ListTile(
                            leading: const Icon(Icons.insert_drive_file_outlined),
                            title: Text(file.name),
                            subtitle: file.mimeType == null ? null : Text(file.mimeType!),
                            trailing: IconButton(
                              tooltip: 'Download',
                              onPressed: () => _saveProjectFile(project, file),
                              icon: const Icon(Icons.download_outlined),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, _ProjectDialogAction.delete),
            child: const Text('Delete project'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ProjectDialogAction.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (action == _ProjectDialogAction.save) {
      await controller.updateActiveProjectInstructions(instructions.text);
    } else if (action == _ProjectDialogAction.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Delete project?'),
          content: const Text('This deletes the project in ChatGPT.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await controller.deleteActiveProject();
      }
    }
    instructions.dispose();
  }

  Future<void> _saveProjectFile(ProjectSummary project, ProjectFile file) async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save project file',
        fileName: _safeFileName(file.name),
      );
      if (path == null || path.isEmpty) {
        return;
      }
      final bytes = await controller.actions.projectFileBytes(project.id, file.id);
      await File(path).writeAsBytes(bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project file saved')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save project file: $error')),
        );
      }
    }
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

  String _safeFileName(String value) {
    final clean = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_')
        .trim();
    return clean.isEmpty ? 'file' : clean;
  }
}

class _InteractiveActions extends StatelessWidget {
  const _InteractiveActions({required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: controller.interactiveActions
              .map(
                (InteractiveAction action) => ActionChip(
                  label: Text(action.label),
                  onPressed: () => controller.triggerInteractiveAction(action),
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
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
    final models = controller.models.isEmpty
        ? const <String>['auto']
        : controller.models;
    final selectedModel = models.contains(controller.selectedModel)
        ? controller.selectedModel
        : models.first;
    final apps = <String>['none', ...controller.appLabels];
    final selectedApp = controller.selectedApp != null &&
            apps.contains(controller.selectedApp)
        ? controller.selectedApp!
        : 'none';

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
          if (controller.appLabels.isNotEmpty) ...<Widget>[
            const SizedBox(width: 6),
            _CompactDropdown(
              tooltip: 'App',
              value: selectedApp,
              values: apps,
              label: (String value) => value == 'none' ? 'Apps' : value,
              onChanged: controller.sending ? null : controller.setApp,
            ),
          ],
          if (controller.activeConversation == null &&
              controller.activeProject == null &&
              controller.activeGpt == null) ...<Widget>[
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('Temporary'),
              selected: controller.temporaryChat,
              onSelected: controller.sending ? null : controller.setTemporaryChat,
            ),
          ],
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
  const _Sidebar({
    required this.controller,
    required this.searchController,
    required this.onCreateProject,
  });

  final ChatController controller;
  final TextEditingController searchController;
  final VoidCallback onCreateProject;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: SegmentedButton<SidebarSection>(
            showSelectedIcon: false,
            segments: const <ButtonSegment<SidebarSection>>[
              ButtonSegment(
                value: SidebarSection.chats,
                icon: Icon(Icons.chat_bubble_outline, size: 17),
                tooltip: 'Chats',
              ),
              ButtonSegment(
                value: SidebarSection.projects,
                icon: Icon(Icons.folder_outlined, size: 17),
                tooltip: 'Projects',
              ),
              ButtonSegment(
                value: SidebarSection.gpts,
                icon: Icon(Icons.explore_outlined, size: 17),
                tooltip: 'GPTs',
              ),
            ],
            selected: <SidebarSection>{controller.sidebarSection},
            onSelectionChanged: (Set<SidebarSection> selection) {
              if (selection.isNotEmpty) {
                searchController.clear();
                controller.setSidebarSection(selection.first);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () {
                final keepContext = controller.activeProject != null &&
                    controller.sidebarSection == SidebarSection.projects;
                controller.newChat(keepContext: keepContext);
                _closeDrawer(context);
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(
                controller.activeProject != null ? 'New project chat' : 'New chat',
              ),
            ),
          ),
        ),
        if (controller.sidebarSection != SidebarSection.gpts &&
            !(controller.sidebarSection == SidebarSection.projects &&
                controller.activeProject == null))
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
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onSubmitted: controller.search,
            ),
          ),
        if (controller.activeProject != null &&
            controller.sidebarSection == SidebarSection.projects)
          ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_back, size: 19),
            title: Text(controller.activeProject!.name),
            onTap: () => controller.setSidebarSection(SidebarSection.projects),
          ),
        Expanded(child: _sidebarBody(context)),
      ],
    );
  }

  Widget _sidebarBody(BuildContext context) {
    if (controller.loadingNavigation) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.sidebarSection == SidebarSection.projects &&
        controller.activeProject == null) {
      return _projectList(context);
    }
    if (controller.sidebarSection == SidebarSection.gpts) {
      return _gptList(context);
    }
    return _conversationList(context);
  }

  Widget _conversationList(BuildContext context) {
    final items = controller.displayedConversations;
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No chats loaded', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        final selected = item.id == controller.activeConversation?.id;
        final pinned = controller.pinnedConversationIds.contains(item.id);
        return ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          leading: pinned ? const Icon(Icons.push_pin, size: 15) : null,
          title: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            controller.selectConversation(item.id);
            _closeDrawer(context);
          },
        );
      },
    );
  }

  Widget _projectList(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onCreateProject,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('New project'),
            ),
          ),
        ),
        Expanded(
          child: controller.projects.isEmpty
              ? const Center(child: Text('No projects'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  itemCount: controller.projects.length,
                  itemBuilder: (BuildContext context, int index) {
                    final item = controller.projects[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.folder_outlined, size: 19),
                      title: Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        controller.openProject(item);
                        _closeDrawer(context);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _gptList(BuildContext context) {
    if (controller.gpts.isEmpty) {
      return const Center(child: Text('No GPTs'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      itemCount: controller.gpts.length,
      itemBuilder: (BuildContext context, int index) {
        final item = controller.gpts[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.auto_awesome_outlined, size: 19),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: item.description == null
              ? null
              : Text(
                  item.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: () {
            controller.openGpt(item);
            _closeDrawer(context);
          },
        );
      },
    );
  }

  void _closeDrawer(BuildContext context) {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen == true) {
      Navigator.pop(context);
    }
  }
}

enum _AttachmentAction { upload, library }

enum _ConversationMenuAction { rename, pin, share, archive, delete }

enum _ProjectDialogAction { save, delete }
