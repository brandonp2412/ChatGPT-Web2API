import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/bridge_client.dart';
import '../model/chat_models.dart';
import '../storage/secure_store.dart';

class ChatController extends ChangeNotifier {
  ChatController({required SecureStore store}) : _store = store;

  final SecureStore _store;
  BridgeClient? _client;
  StreamSubscription<BridgeEvent>? _backgroundSubscription;

  BridgeSettings settings = const BridgeSettings(
    baseUrl: 'http://127.0.0.1:8080',
  );
  List<ConversationSummary> conversations = const <ConversationSummary>[];
  ChatConversation? activeConversation;
  List<String> models = const <String>['auto'];
  List<String> reasoningLevels = const <String>[];
  List<String> toolLabels = const <String>[];
  List<UploadedAttachment> pendingAttachments = const <UploadedAttachment>[];

  String selectedModel = 'auto';
  String? selectedReasoningLevel;
  String selectedMode = 'normal';
  String searchQuery = '';
  String streamingText = '';
  ChatMessage? optimisticUserMessage;
  String? errorMessage;
  bool initialized = false;
  bool connecting = false;
  bool loadingConversation = false;
  bool sending = false;
  bool connected = false;

  BridgeClient get client {
    final value = _client;
    if (value == null) {
      throw const BridgeException('Bridge client is not initialized');
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

  Future<void> initialize() async {
    settings = await _store.loadSettings();
    _replaceClient();
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
    _replaceClient();
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
      ]);
      final active = activeConversation;
      if (active != null && active.id.isNotEmpty) {
        await selectConversation(active.id, preserveLoadingState: true);
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
    final items = searchQuery.trim().isEmpty
        ? await client.conversations(limit: 80)
        : await client.searchConversations(searchQuery.trim());
    conversations = items;
    await _persistCache();
    notifyListeners();
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

  Future<void> newChat() async {
    await _stopBackgroundEvents();
    activeConversation = null;
    optimisticUserMessage = null;
    streamingText = '';
    pendingAttachments = const <UploadedAttachment>[];
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
      optimisticUserMessage = null;
      streamingText = '';
      await _persistCache();
      _startBackgroundEvents(id);
    } on Object catch (error) {
      errorMessage = _message(error);
    } finally {
      loadingConversation = false;
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

  Future<void> send(String prompt) async {
    final text = prompt.trim();
    if (sending || (text.isEmpty && pendingAttachments.isEmpty)) {
      return;
    }
    await _stopBackgroundEvents();
    sending = true;
    errorMessage = null;
    streamingText = '';
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
    pendingAttachments = const <UploadedAttachment>[];
    notifyListeners();

    String? completedConversationId;
    try {
      await for (final event in client.send(
        prompt: text,
        conversationId: activeConversation?.id,
        model: selectedModel,
        reasoningLevel: selectedReasoningLevel,
        mode: selectedMode,
        attachmentIds: attachmentIds,
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
      await refreshConversations();
      final id = activeConversation?.id ?? completedConversationId;
      if (id != null && id.isNotEmpty) {
        _startBackgroundEvents(id);
      }
      await _persistCache();
    } on Object catch (error) {
      errorMessage = _message(error);
      // Do not fake a completed assistant response. Keep any streamed text on
      // screen so the user can see what arrived before the transport failed.
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
    notifyListeners();
    unawaited(_persistCache());
  }

  Future<void> _loadComposerOptions() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      client.models(),
      client.reasoningLevels(),
      client.tools(),
    ]);
    final loadedModels = results[0] as List<String>;
    models = loadedModels.isEmpty
        ? const <String>['auto']
        : <String>{'auto', ...loadedModels}.toList(growable: false);
    reasoningLevels = results[1] as List<String>;
    toolLabels = results[2] as List<String>;
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

  void _replaceClient() {
    _client?.close();
    _client = BridgeClient(settings);
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
  }

  Future<void> _persistCache() async {
    await _store.writeCache(<String, dynamic>{
      'conversations': conversations
          .map((ConversationSummary item) => item.toJson())
          .toList(growable: false),
      'active_conversation': activeConversation?.toJson(),
      'selected_model': selectedModel,
      'selected_reasoning': selectedReasoningLevel,
      'selected_mode': selectedMode,
      'cached_at': DateTime.now().toUtc().toIso8601String(),
    });
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
    super.dispose();
  }
}
