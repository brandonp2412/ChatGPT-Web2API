import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/bridge_client.dart';
import '../api/parity_actions_api.dart';
import '../model/account_models.dart';
import '../model/chat_models.dart';
import '../storage/secure_store.dart';

enum SidebarSection { chats, projects, gpts }

class ChatController extends ChangeNotifier {
  ChatController({required SecureStore store}) : _store = store;

  final SecureStore _store;
  BridgeClient? _client;
  ParityActionsApi? _actionsApi;
  StreamSubscription<BridgeEvent>? _backgroundSubscription;

  BridgeSettings settings = const BridgeSettings(
    baseUrl: 'http://127.0.0.1:8080',
  );
  List<ConversationSummary> conversations = const <ConversationSummary>[];
  List<ProjectSummary> projects = const <ProjectSummary>[];
  List<ProjectFile> activeProjectFiles = const <ProjectFile>[];
  List<GptSummary> gpts = const <GptSummary>[];
  List<LibraryItem> libraryItems = const <LibraryItem>[];
  List<MemoryItem> memoryItems = const <MemoryItem>[];
  List<InteractiveAction> interactiveActions = const <InteractiveAction>[];
  ChatConversation? activeConversation;
  ProjectSummary? activeProject;
  GptSummary? activeGpt;
  ShareResult? activeShare;
  Set<String> pinnedConversationIds = <String>{};
  List<String> models = const <String>['auto'];
  List<String> reasoningLevels = const <String>[];
  List<String> toolLabels = const <String>[];
  List<UploadedAttachment> pendingAttachments = const <UploadedAttachment>[];
  List<String> pendingLibraryFiles = const <String>[];

  SidebarSection sidebarSection = SidebarSection.chats;
  String selectedModel = 'auto';
  String? selectedReasoningLevel;
  String selectedMode = 'normal';
  String? selectedApp;
  String searchQuery = '';
  String streamingText = '';
  ChatMessage? optimisticUserMessage;
  String? errorMessage;
  bool temporaryChat = false;
  bool initialized = false;
  bool connecting = false;
  bool loadingConversation = false;
  bool loadingNavigation = false;
  bool loadingLibrary = false;
  bool loadingMemories = false;
  bool parityActionBusy = false;
  bool sending = false;
  bool connected = false;

  BridgeClient get client {
    final value = _client;
    if (value == null) {
      throw const BridgeException('Bridge client is not initialized');
    }
    return value;
  }

  ParityActionsApi get actions {
    final value = _actionsApi;
    if (value == null) {
      throw const BridgeException('Parity action client is not initialized');
    }
    return value;
  }

  List<ChatMessage> get visibleMessages {
    final messages = <ChatMessage>[...?activeConversation?.messages];
    final optimistic = optimisticUserMessage;
    if (optimistic != null &&
        !messages.any((ChatMessage message) => message.id == optimistic.id)) {
      messages.add(optimistic);
    }
    if (streamingText.isNotEmpty) {
      messages.add(
        ChatMessage(
          id: 'streaming-assistant',
          role: 'assistant',
          text: streamingText,
          status: 'in_progress',
        ),
      );
    }
    return messages;
  }

  List<ConversationSummary> get displayedConversations {
    if (pinnedConversationIds.isEmpty) {
      return conversations;
    }
    final items = List<ConversationSummary>.of(conversations, growable: false);
    items.sort((ConversationSummary a, ConversationSummary b) {
      final aPinned = pinnedConversationIds.contains(a.id);
      final bPinned = pinnedConversationIds.contains(b.id);
      if (aPinned != bPinned) {
        return aPinned ? -1 : 1;
      }
      final aTime = a.updateTime;
      final bTime = b.updateTime;
      if (aTime != null && bTime != null) {
        return bTime.compareTo(aTime);
      }
      return 0;
    });
    return items;
  }

  bool get activeConversationPinned {
    final id = activeConversation?.id;
    return id != null && pinnedConversationIds.contains(id);
  }

  List<String> get availableModes {
    final normalized = toolLabels.map((String item) => item.toLowerCase()).join(' | ');
    final result = <String>['normal'];
    if (normalized.contains('search')) {
      result.add('search');
    }
    if (normalized.contains('image')) {
      result.add('image');
    }
    if (normalized.contains('research')) {
      result.add('deep_research');
    }
    if (normalized.contains('study')) {
      result.add('study');
    }
    return result;
  }

  List<String> get appLabels {
    return toolLabels
        .where((String label) => !_isBuiltInModeLabel(label))
        .toSet()
        .toList(growable: false);
  }

  Future<void> initialize() async {
    settings = await _store.loadSettings();
    _replaceClients();
    await _restoreCache();
    initialized = true;
    notifyListeners();
    await connect(silent: true);
  }

  Future<void> saveSettings(BridgeSettings next) async {
    final validation = BridgeSettings.validateBaseUrl(next.baseUrl);
    if (validation != null) {
      throw ArgumentError(validation);
    }
    await _store.saveSettings(next);
    settings = BridgeSettings(
      baseUrl: BridgeSettings.normalizedBaseUrl(next.baseUrl),
      apiKey: next.apiKey.trim(),
    );
    await _stopBackgroundEvents();
    _replaceClients();
    connected = false;
    errorMessage = null;
    notifyListeners();
    await connect();
  }

  Future<void> connect({bool silent = false}) async {
    if (connecting) {
      return;
    }
    connecting = true;
    if (!silent) {
      errorMessage = null;
    }
    notifyListeners();
    try {
      final health = await client.health();
      final status = (health['status'] ?? '').toString();
      connected = status == 'healthy' || status == 'starting';
      if (!connected && status.isNotEmpty) {
        throw BridgeException('Bridge is $status');
      }
      await Future.wait<void>(<Future<void>>[
        refreshConversations(),
        _loadComposerOptions(),
        _loadNavigation(),
      ]);
      await refreshPins(silent: true);
      final active = activeConversation;
      if (active != null && active.id.isNotEmpty) {
        await selectConversation(active.id, preserveLoadingState: true);
      }
      if (activeProject != null) {
        await loadActiveProjectFiles(silent: true);
      }
      errorMessage = null;
    } on Object catch (error) {
      connected = false;
      if (!silent || conversations.isEmpty) {
        errorMessage = _message(error);
      }
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> refreshConversations() async {
    List<ConversationSummary> items;
    if (searchQuery.trim().isNotEmpty) {
      items = await client.searchConversations(searchQuery.trim());
    } else if (activeProject != null) {
      items = await client.projectConversations(activeProject!.id);
    } else {
      items = await _loadAllTopLevelConversations();
    }
    conversations = items;
    await _persistCache();
    notifyListeners();
  }

  Future<List<ConversationSummary>> _loadAllTopLevelConversations() async {
    const pageSize = 100;
    const maxPages = 20;
    final result = <ConversationSummary>[];
    for (var page = 0; page < maxPages; page++) {
      final items = await client.conversations(
        offset: page * pageSize,
        limit: pageSize,
      );
      result.addAll(items);
      if (items.length < pageSize) {
        break;
      }
    }
    return result;
  }

  Future<void> search(String query) async {
    searchQuery = query;
    try {
      await refreshConversations();
    } on Object catch (error) {
      errorMessage = _message(error);
      notifyListeners();
    }
  }

  Future<void> setSidebarSection(SidebarSection section) async {
    sidebarSection = section;
    searchQuery = '';
    loadingNavigation = true;
    await _stopBackgroundEvents();
    notifyListeners();
    try {
      activeConversation = null;
      activeShare = null;
      interactiveActions = const <InteractiveAction>[];
      if (section == SidebarSection.chats) {
        activeProject = null;
        activeProjectFiles = const <ProjectFile>[];
        activeGpt = null;
        conversations = await _loadAllTopLevelConversations();
      } else if (section == SidebarSection.projects) {
        activeProject = null;
        activeProjectFiles = const <ProjectFile>[];
        activeGpt = null;
        conversations = const <ConversationSummary>[];
        projects = await client.projects();
      } else {
        activeProject = null;
        activeProjectFiles = const <ProjectFile>[];
        activeGpt = null;
        conversations = const <ConversationSummary>[];
        gpts = await client.gpts();
      }
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingNavigation = false;
      notifyListeners();
    }
  }

  Future<void> openProject(ProjectSummary project) async {
    await _stopBackgroundEvents();
    activeProject = project;
    activeGpt = null;
    activeConversation = null;
    activeShare = null;
    temporaryChat = false;
    sidebarSection = SidebarSection.projects;
    loadingNavigation = true;
    notifyListeners();
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        client.projectConversations(project.id),
        actions.projectFiles(project.id),
      ]);
      conversations = results[0] as List<ConversationSummary>;
      activeProjectFiles = results[1] as List<ProjectFile>;
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingNavigation = false;
      notifyListeners();
    }
  }

  Future<void> openGpt(GptSummary gpt) async {
    await _stopBackgroundEvents();
    activeGpt = gpt;
    activeProject = null;
    activeProjectFiles = const <ProjectFile>[];
    activeConversation = null;
    activeShare = null;
    temporaryChat = false;
    sidebarSection = SidebarSection.gpts;
    conversations = const <ConversationSummary>[];
    errorMessage = null;
    notifyListeners();
    await _persistCache();
  }

  Future<void> newChat({bool keepContext = false}) async {
    await _stopBackgroundEvents();
    activeConversation = null;
    activeShare = null;
    optimisticUserMessage = null;
    streamingText = '';
    interactiveActions = const <InteractiveAction>[];
    pendingAttachments = const <UploadedAttachment>[];
    pendingLibraryFiles = const <String>[];
    temporaryChat = false;
    if (!keepContext) {
      activeProject = null;
      activeProjectFiles = const <ProjectFile>[];
      activeGpt = null;
      sidebarSection = SidebarSection.chats;
      conversations = await _loadAllTopLevelConversations().catchError(
            (Object _) => conversations,
          );
    }
    errorMessage = null;
    notifyListeners();
    await _persistCache();
  }

  Future<void> selectConversation(
    String id, {
    bool preserveLoadingState = false,
  }) async {
    if (id.isEmpty) {
      return;
    }
    await _stopBackgroundEvents();
    if (!preserveLoadingState) {
      loadingConversation = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      activeConversation = await client.conversation(id);
      activeShare = null;
      temporaryChat = false;
      optimisticUserMessage = null;
      streamingText = '';
      await _persistCache();
      _startBackgroundEvents(id);
      await refreshInteractiveActions();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingConversation = false;
      notifyListeners();
    }
  }

  Future<void> renameActiveConversation(String title) async {
    final active = activeConversation;
    final clean = title.trim();
    if (active == null || clean.isEmpty || sending) {
      return;
    }
    try {
      activeConversation = await client.renameConversation(active.id, clean);
      await refreshConversations();
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
      notifyListeners();
    }
  }

  Future<void> archiveActiveConversation() async {
    final active = activeConversation;
    if (active == null || sending) {
      return;
    }
    try {
      await client.archiveConversation(active.id, true);
      await newChat(keepContext: activeProject != null || activeGpt != null);
      await refreshConversations();
      await refreshPins(silent: true);
    } on Object catch (error) {
      errorMessage = _message(error);
      notifyListeners();
    }
  }

  Future<void> deleteActiveConversation() async {
    final active = activeConversation;
    if (active == null || sending) {
      return;
    }
    try {
      await client.deleteConversation(active.id);
      pinnedConversationIds.remove(active.id);
      await newChat(keepContext: activeProject != null || activeGpt != null);
      await refreshConversations();
    } on Object catch (error) {
      errorMessage = _message(error);
      notifyListeners();
    }
  }

  Future<void> addAttachment(File file) async {
    if (sending) {
      return;
    }
    errorMessage = null;
    notifyListeners();
    try {
      final uploaded = await client.uploadAttachment(file);
      pendingAttachments = <UploadedAttachment>[...pendingAttachments, uploaded];
    } on Object catch (error) {
      errorMessage = _message(error);
    }
    notifyListeners();
  }

  void removePendingAttachment(String id) {
    pendingAttachments = pendingAttachments
        .where((UploadedAttachment item) => item.id != id)
        .toList(growable: false);
    notifyListeners();
  }

  Future<List<LibraryItem>> loadLibrary() async {
    loadingLibrary = true;
    notifyListeners();
    try {
      libraryItems = await client.library();
      return libraryItems;
    } on Object catch (error) {
      errorMessage = _message(error);
      return const <LibraryItem>[];
    } finally {
      loadingLibrary = false;
      notifyListeners();
    }
  }

  void addLibraryFiles(Iterable<String> names) {
    pendingLibraryFiles = <String>{...pendingLibraryFiles, ...names}
        .where((String item) => item.trim().isNotEmpty)
        .toList(growable: false);
    notifyListeners();
  }

  void removeLibraryFile(String name) {
    pendingLibraryFiles = pendingLibraryFiles
        .where((String item) => item != name)
        .toList(growable: false);
    notifyListeners();
  }

  Future<void> send(String prompt) async {
    final text = prompt.trim();
    if (sending ||
        (text.isEmpty &&
            pendingAttachments.isEmpty &&
            pendingLibraryFiles.isEmpty)) {
      return;
    }
    await _stopBackgroundEvents();
    sending = true;
    errorMessage = null;
    streamingText = '';
    interactiveActions = const <InteractiveAction>[];
    optimisticUserMessage = text.isEmpty
        ? null
        : ChatMessage(
            id: 'client-${DateTime.now().microsecondsSinceEpoch}',
            role: 'user',
            text: text,
          );
    final attachmentIds = pendingAttachments
        .map((UploadedAttachment item) => item.id)
        .toList(growable: false);
    final libraryFiles = List<String>.of(pendingLibraryFiles, growable: false);
    pendingAttachments = const <UploadedAttachment>[];
    pendingLibraryFiles = const <String>[];
    notifyListeners();

    String? completedConversationId;
    try {
      await for (final event in client.send(
        prompt: text,
        conversationId: activeConversation?.id,
        model: selectedModel,
        reasoningLevel: selectedReasoningLevel,
        mode: selectedMode,
        projectId: activeProject?.id,
        gizmoId: activeGpt?.id,
        app: selectedApp,
        temporary: temporaryChat,
        attachmentIds: attachmentIds,
        libraryFiles: libraryFiles,
      )) {
        if (event.type == 'response.error') {
          throw BridgeException(
            (event.data['message'] ?? event.data['error'] ?? 'ChatGPT generation failed')
                .toString(),
            code: event.data['code']?.toString(),
          );
        }
        final delta = event.delta;
        if (delta.isNotEmpty) {
          streamingText += delta;
        }
        if (event.type == 'ui.actions' && event.data['actions'] is List) {
          interactiveActions = _parseInteractiveActions(event.data['actions']);
        }
        final snapshot = event.conversation;
        if (snapshot != null) {
          activeConversation = snapshot;
          optimisticUserMessage = null;
          streamingText = '';
          completedConversationId = snapshot.id;
          await _persistCache();
        }
        completedConversationId = event.conversationId ?? completedConversationId;
        notifyListeners();
      }

      if (activeConversation == null && completedConversationId != null) {
        activeConversation = await client.conversation(completedConversationId);
      } else if (activeConversation != null && streamingText.isNotEmpty) {
        final id = activeConversation!.id;
        if (id.isNotEmpty) {
          activeConversation = await client.conversation(id);
        }
      }
      optimisticUserMessage = null;
      streamingText = '';
      temporaryChat = false;
      await refreshConversations();
      await refreshPins(silent: true);
      final id = activeConversation?.id ?? completedConversationId;
      if (id != null && id.isNotEmpty) {
        _startBackgroundEvents(id);
        await refreshInteractiveActions();
      }
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
      // Keep partial streamed output visible. A failed transport must never be
      // represented as a fabricated completed assistant response.
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> stopGeneration() async {
    if (!sending) {
      return;
    }
    try {
      await client.stop();
    } on Object catch (error) {
      errorMessage = _message(error);
    }
    notifyListeners();
  }

  Future<void> selectBranch(String targetNodeId) async {
    final active = activeConversation;
    if (active == null || targetNodeId.isEmpty || sending) {
      return;
    }
    loadingConversation = true;
    notifyListeners();
    try {
      final updated = await client.selectBranch(active.id, targetNodeId);
      activeConversation = updated ?? await client.conversation(active.id);
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingConversation = false;
      notifyListeners();
    }
  }

  Future<void> regenerate(ChatMessage message) async {
    final active = activeConversation;
    if (active == null || sending || message.role != 'assistant') {
      return;
    }
    loadingConversation = true;
    notifyListeners();
    try {
      activeConversation = await client.messageAction(
        conversationId: active.id,
        action: 'regenerate',
        messageId: message.id,
      );
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingConversation = false;
      notifyListeners();
    }
  }

  Future<void> editMessage(ChatMessage message, String replacement) async {
    final active = activeConversation;
    final clean = replacement.trim();
    if (active == null || sending || message.role != 'user' || clean.isEmpty) {
      return;
    }
    loadingConversation = true;
    notifyListeners();
    try {
      activeConversation = await client.messageAction(
        conversationId: active.id,
        action: 'edit',
        messageId: message.id,
        text: clean,
      );
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingConversation = false;
      notifyListeners();
    }
  }

  Future<void> branchInNewChat(ChatMessage message) async {
    final active = activeConversation;
    if (active == null || sending) {
      return;
    }
    loadingConversation = true;
    notifyListeners();
    try {
      activeConversation = await client.messageAction(
        conversationId: active.id,
        action: 'branch',
        messageId: message.id,
      );
      activeProject = null;
      activeProjectFiles = const <ProjectFile>[];
      activeGpt = null;
      sidebarSection = SidebarSection.chats;
      await refreshConversations();
      await refreshPins(silent: true);
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingConversation = false;
      notifyListeners();
    }
  }

  Future<void> runBlockAction(
    ChatMessage message,
    String action, {
    String? text,
  }) async {
    final active = activeConversation;
    if (active == null || message.id.isEmpty || sending || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      activeConversation = await actions.blockAction(
        conversationId: active.id,
        messageId: message.id,
        action: action,
        text: text,
      );
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<void> sendFeedback(ChatMessage message, String rating) async {
    final active = activeConversation;
    if (active == null || message.id.isEmpty || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      await actions.feedback(
        conversationId: active.id,
        messageId: message.id,
        rating: rating,
      );
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshPins({bool silent = false}) async {
    try {
      pinnedConversationIds = await actions.pinnedConversationIds();
      notifyListeners();
    } on Object catch (error) {
      if (!silent) {
        errorMessage = _message(error);
        notifyListeners();
      }
    }
  }

  Future<void> toggleActivePin() async {
    final active = activeConversation;
    if (active == null || parityActionBusy) {
      return;
    }
    final next = !pinnedConversationIds.contains(active.id);
    parityActionBusy = true;
    notifyListeners();
    try {
      await actions.setPinned(active.id, next);
      if (next) {
        pinnedConversationIds.add(active.id);
      } else {
        pinnedConversationIds.remove(active.id);
      }
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<ShareResult?> shareActiveConversation() async {
    final active = activeConversation;
    if (active == null || parityActionBusy) {
      return null;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      activeShare = await actions.shareConversation(active.id);
      return activeShare;
    } on Object catch (error) {
      errorMessage = _message(error);
      return null;
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<void> deleteActiveShare() async {
    final share = activeShare;
    if (share == null || share.id.isEmpty || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      await actions.deleteShare(share.id);
      activeShare = null;
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<List<MemoryItem>> loadMemories() async {
    loadingMemories = true;
    notifyListeners();
    try {
      memoryItems = await actions.memories();
      return memoryItems;
    } on Object catch (error) {
      errorMessage = _message(error);
      return memoryItems;
    } finally {
      loadingMemories = false;
      notifyListeners();
    }
  }

  Future<void> createMemory(String content) async {
    final clean = content.trim();
    if (clean.isEmpty || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      final created = await actions.createMemory(clean);
      memoryItems = <MemoryItem>[...memoryItems, created];
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<void> deleteMemory(String memoryId) async {
    if (memoryId.isEmpty || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      await actions.deleteMemory(memoryId);
      memoryItems = memoryItems
          .where((MemoryItem item) => item.id != memoryId)
          .toList(growable: false);
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<ProjectSummary?> createProject({
    required String name,
    String instructions = '',
  }) async {
    final clean = name.trim();
    if (clean.isEmpty || parityActionBusy) {
      return null;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      final project = await actions.createProject(
        name: clean,
        instructions: instructions.trim(),
      );
      projects = <ProjectSummary>[project, ...projects];
      return project;
    } on Object catch (error) {
      errorMessage = _message(error);
      return null;
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<void> updateActiveProjectInstructions(String instructions) async {
    final project = activeProject;
    if (project == null || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      final updated = await actions.updateProjectInstructions(
        project.id,
        instructions.trim(),
      );
      activeProject = updated;
      projects = projects
          .map((ProjectSummary item) => item.id == updated.id ? updated : item)
          .toList(growable: false);
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<void> deleteActiveProject() async {
    final project = activeProject;
    if (project == null || parityActionBusy) {
      return;
    }
    parityActionBusy = true;
    notifyListeners();
    try {
      await actions.deleteProject(project.id);
      projects = projects
          .where((ProjectSummary item) => item.id != project.id)
          .toList(growable: false);
      activeProject = null;
      activeProjectFiles = const <ProjectFile>[];
      activeConversation = null;
      conversations = const <ConversationSummary>[];
      sidebarSection = SidebarSection.projects;
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      parityActionBusy = false;
      notifyListeners();
    }
  }

  Future<List<ProjectFile>> loadActiveProjectFiles({bool silent = false}) async {
    final project = activeProject;
    if (project == null) {
      activeProjectFiles = const <ProjectFile>[];
      return activeProjectFiles;
    }
    try {
      activeProjectFiles = await actions.projectFiles(project.id);
      notifyListeners();
      return activeProjectFiles;
    } on Object catch (error) {
      if (!silent) {
        errorMessage = _message(error);
        notifyListeners();
      }
      return activeProjectFiles;
    }
  }

  Future<void> refreshInteractiveActions() async {
    final id = activeConversation?.id;
    if (id == null || id.isEmpty) {
      interactiveActions = const <InteractiveAction>[];
      return;
    }
    try {
      interactiveActions = await client.interactiveActions(conversationId: id);
      notifyListeners();
    } on Object {
      interactiveActions = const <InteractiveAction>[];
    }
  }

  Future<void> triggerInteractiveAction(InteractiveAction action) async {
    final id = activeConversation?.id;
    if (id == null || id.isEmpty) {
      return;
    }
    try {
      await client.triggerInteractiveAction(
        label: action.label,
        conversationId: id,
      );
      interactiveActions = const <InteractiveAction>[];
      _startBackgroundEvents(id);
      notifyListeners();
    } on Object catch (error) {
      errorMessage = _message(error);
      notifyListeners();
    }
  }

  void setModel(String value) {
    selectedModel = value;
    notifyListeners();
    unawaited(_persistCache());
  }

  void setReasoningLevel(String? value) {
    selectedReasoningLevel = value == null || value == 'auto' ? null : value;
    notifyListeners();
    unawaited(_persistCache());
  }

  void setMode(String value) {
    selectedMode = value;
    if (value != 'normal') {
      selectedApp = null;
    }
    notifyListeners();
    unawaited(_persistCache());
  }

  void setApp(String? value) {
    selectedApp = value == null || value == 'none' || value.trim().isEmpty
        ? null
        : value.trim();
    if (selectedApp != null) {
      selectedMode = 'normal';
    }
    notifyListeners();
    unawaited(_persistCache());
  }

  void setTemporaryChat(bool value) {
    if (activeConversation != null) {
      return;
    }
    temporaryChat = value;
    notifyListeners();
  }

  Future<void> _loadComposerOptions() async {
    final results = await Future.wait<List<String>>(<Future<List<String>>>[
      client.models(),
      client.reasoningLevels(),
      client.tools(),
    ]);
    final loadedModels = results[0];
    models = loadedModels.isEmpty
        ? const <String>['auto']
        : <String>{'auto', ...loadedModels}.toList(growable: false);
    reasoningLevels = results[1];
    toolLabels = results[2];
    if (!models.contains(selectedModel)) {
      selectedModel = 'auto';
    }
    if (selectedReasoningLevel != null &&
        !reasoningLevels.contains(selectedReasoningLevel)) {
      selectedReasoningLevel = null;
    }
    if (!availableModes.contains(selectedMode)) {
      selectedMode = 'normal';
    }
    if (selectedApp != null && !appLabels.contains(selectedApp)) {
      selectedApp = null;
    }
  }

  Future<void> _loadNavigation() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      client.projects(),
      client.gpts(),
    ]);
    projects = results[0] as List<ProjectSummary>;
    gpts = results[1] as List<GptSummary>;
  }

  List<InteractiveAction> _parseInteractiveActions(dynamic raw) {
    if (raw is! List) {
      return const <InteractiveAction>[];
    }
    return raw
        .whereType<Map>()
        .map((Map item) => InteractiveAction.fromJson(item.cast<String, dynamic>()))
        .where((InteractiveAction item) => item.label.isNotEmpty)
        .toList(growable: false);
  }

  void _startBackgroundEvents(String conversationId) {
    unawaited(_stopBackgroundEvents());
    _backgroundSubscription = client.backgroundEvents(conversationId).listen(
      (BridgeEvent event) {
        final snapshot = event.conversation;
        if (snapshot != null && activeConversation?.id == conversationId) {
          activeConversation = snapshot;
          notifyListeners();
          unawaited(_persistCache());
        }
        if (event.type == 'ui.actions' && event.data['actions'] is List) {
          interactiveActions = _parseInteractiveActions(event.data['actions']);
          notifyListeners();
        }
      },
      onError: (Object _) {
        // The primary request path remains usable. Re-opening the conversation
        // starts a fresh background stream, so a transient disconnect is not a
        // user-facing fatal error.
      },
    );
  }

  Future<void> _stopBackgroundEvents() async {
    final subscription = _backgroundSubscription;
    _backgroundSubscription = null;
    await subscription?.cancel();
  }

  void _replaceClients() {
    _client?.close();
    _actionsApi?.close();
    _client = BridgeClient(settings);
    _actionsApi = ParityActionsApi(settings);
  }

  Future<void> _restoreCache() async {
    final cache = await _store.readCache();
    if (cache == null) {
      return;
    }
    final summaryRaw = cache['conversations'];
    if (summaryRaw is List) {
      conversations = summaryRaw
          .whereType<Map>()
          .map((Map item) => ConversationSummary.fromJson(item.cast<String, dynamic>()))
          .where((ConversationSummary item) => item.id.isNotEmpty)
          .toList(growable: false);
    }
    final activeRaw = cache['active_conversation'];
    if (activeRaw is Map) {
      activeConversation = ChatConversation.fromJson(activeRaw.cast<String, dynamic>());
    }
    final cachedModel = cache['selected_model']?.toString();
    if (cachedModel != null && cachedModel.isNotEmpty) {
      selectedModel = cachedModel;
    }
    final cachedReasoning = cache['selected_reasoning']?.toString();
    if (cachedReasoning != null && cachedReasoning.isNotEmpty) {
      selectedReasoningLevel = cachedReasoning;
    }
    final cachedMode = cache['selected_mode']?.toString();
    if (cachedMode != null && cachedMode.isNotEmpty) {
      selectedMode = cachedMode;
    }
    final cachedApp = cache['selected_app']?.toString();
    if (cachedApp != null && cachedApp.isNotEmpty) {
      selectedApp = cachedApp;
    }
    final projectId = cache['active_project_id']?.toString();
    final projectName = cache['active_project_name']?.toString();
    if (projectId != null && projectId.isNotEmpty) {
      activeProject = ProjectSummary(
        id: projectId,
        name: projectName?.isNotEmpty == true ? projectName! : 'Project',
      );
      sidebarSection = SidebarSection.projects;
    }
    final gptId = cache['active_gpt_id']?.toString();
    final gptName = cache['active_gpt_name']?.toString();
    if (gptId != null && gptId.isNotEmpty) {
      activeGpt = GptSummary(
        id: gptId,
        name: gptName?.isNotEmpty == true ? gptName! : 'GPT',
      );
      activeProject = null;
      sidebarSection = SidebarSection.gpts;
    }
  }

  Future<void> _persistCache() async {
    await _store.writeCache(<String, dynamic>{
      'conversations': conversations
          .map((ConversationSummary item) => item.toJson())
          .toList(growable: false),
      'active_conversation': activeConversation?.toJson(),
      'active_project_id': activeProject?.id,
      'active_project_name': activeProject?.name,
      'active_gpt_id': activeGpt?.id,
      'active_gpt_name': activeGpt?.name,
      'selected_model': selectedModel,
      'selected_reasoning': selectedReasoningLevel,
      'selected_mode': selectedMode,
      'selected_app': selectedApp,
      'cached_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  bool _isBuiltInModeLabel(String label) {
    final value = label.toLowerCase();
    return value.contains('search') ||
        value.contains('create image') ||
        value.contains('image generation') ||
        value.contains('deep research') ||
        value == 'research' ||
        value.contains('study');
  }

  String _message(Object error) {
    if (error is BridgeException) {
      return error.message;
    }
    if (error is ArgumentError) {
      return error.message?.toString() ?? 'Invalid value';
    }
    return 'Request failed: $error';
  }

  @override
  void dispose() {
    unawaited(_backgroundSubscription?.cancel());
    _client?.close();
    _actionsApi?.close();
    super.dispose();
  }
}
