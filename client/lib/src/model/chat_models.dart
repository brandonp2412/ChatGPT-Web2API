import 'dart:convert';

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    this.updateTime,
    this.projectId,
  });

  final String id;
  final String title;
  final DateTime? updateTime;
  final String? projectId;

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    return ConversationSummary(
      id: _string(json['id']) ?? _string(json['conversation_id']) ?? '',
      title: _string(json['title']) ?? 'New chat',
      updateTime: _date(json['update_time'] ?? json['updated_at']),
      projectId: _string(json['gizmo_id'] ?? json['project_id']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'update_time': updateTime?.toIso8601String(),
        'project_id': projectId,
      };
}

class ChatCitation {
  const ChatCitation({this.url, this.title, this.text});

  final String? url;
  final String? title;
  final String? text;

  factory ChatCitation.fromJson(Map<String, dynamic> json) => ChatCitation(
        url: _string(json['url']),
        title: _string(json['title']),
        text: _string(json['text'] ?? json['snippet']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'title': title,
        'text': text,
      };
}

class ChatAsset {
  const ChatAsset({
    this.pointer,
    this.fileName,
    this.mimeType,
    this.url,
    this.type,
  });

  final String? pointer;
  final String? fileName;
  final String? mimeType;
  final String? url;
  final String? type;

  bool get isImage =>
      type == 'image' || (mimeType?.toLowerCase().startsWith('image/') ?? false);

  factory ChatAsset.fromJson(Map<String, dynamic> json) => ChatAsset(
        pointer: _string(json['asset_pointer'] ?? json['pointer']),
        fileName: _string(json['file_name'] ?? json['name']),
        mimeType: _string(json['mime_type']),
        url: _string(json['url'] ?? json['download_url']),
        type: _string(json['type']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'asset_pointer': pointer,
        'file_name': fileName,
        'mime_type': mimeType,
        'url': url,
        'type': type,
      };
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.nodeId,
    this.status,
    this.endTurn,
    this.citations = const <ChatCitation>[],
    this.assets = const <ChatAsset>[],
    this.blocks = const <Map<String, dynamic>>[],
  });

  final String id;
  final String role;
  final String text;
  final String? nodeId;
  final String? status;
  final bool? endTurn;
  final List<ChatCitation> citations;
  final List<ChatAsset> assets;
  final List<Map<String, dynamic>> blocks;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final parsedBlocks = _parseBlocks(json['blocks']);
    final parsedCitations = <ChatCitation>[
      ..._parseCitations(json['citations']),
      ..._citationsFromBlocks(parsedBlocks),
    ];
    final parsedAssets = <ChatAsset>[
      ..._parseAssets(json['assets']),
      ..._assetsFromBlocks(parsedBlocks),
    ];
    return ChatMessage(
      id: _string(json['id']) ?? _string(json['message_id']) ?? '',
      role: _string(json['role']) ?? 'assistant',
      text: _string(json['text']) ?? _contentText(json['content']),
      nodeId: _string(json['node_id']),
      status: _string(json['status']),
      endTurn: json['end_turn'] is bool ? json['end_turn'] as bool : null,
      citations: _dedupeCitations(parsedCitations),
      assets: _dedupeAssets(parsedAssets),
      blocks: parsedBlocks,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': role,
        'text': text,
        'node_id': nodeId,
        'status': status,
        'end_turn': endTurn,
        'citations': citations.map((ChatCitation item) => item.toJson()).toList(),
        'assets': assets.map((ChatAsset item) => item.toJson()).toList(),
        'blocks': blocks,
      };
}

class ConversationNode {
  const ConversationNode({
    required this.id,
    this.parent,
    this.children = const <String>[],
    this.message,
  });

  final String id;
  final String? parent;
  final List<String> children;
  final ChatMessage? message;

  factory ConversationNode.fromJson(String id, Map<String, dynamic> json) {
    final rawChildren = json['children'];
    final rawMessage = json['message'];
    final parsedMessage = rawMessage is Map
        ? ChatMessage.fromJson(rawMessage.cast<String, dynamic>())
        : null;
    return ConversationNode(
      id: id,
      parent: _string(json['parent']),
      children: rawChildren is List
          ? rawChildren.map((dynamic value) => value.toString()).toList(growable: false)
          : const <String>[],
      message: parsedMessage == null
          ? null
          : ChatMessage(
              id: parsedMessage.id,
              role: parsedMessage.role,
              text: parsedMessage.text,
              nodeId: parsedMessage.nodeId ?? id,
              status: parsedMessage.status,
              endTurn: parsedMessage.endTurn,
              citations: parsedMessage.citations,
              assets: parsedMessage.assets,
              blocks: parsedMessage.blocks,
            ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'parent': parent,
        'children': children,
        'message': message?.toJson(),
      };
}

class ResearchReport {
  const ResearchReport({
    this.id,
    required this.text,
    this.status,
    this.citations = const <ChatCitation>[],
    this.assets = const <ChatAsset>[],
  });

  final String? id;
  final String text;
  final String? status;
  final List<ChatCitation> citations;
  final List<ChatAsset> assets;

  factory ResearchReport.fromJson(Map<String, dynamic> json) {
    return ResearchReport(
      id: _string(json['id']),
      text: _string(json['text']) ?? '',
      status: _string(json['status']),
      citations: _parseCitations(json['citations']),
      assets: _parseAssets(json['assets']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'status': status,
        'citations': citations.map((ChatCitation item) => item.toJson()).toList(),
        'assets': assets.map((ChatAsset item) => item.toJson()).toList(),
      };
}

class ChatConversation {
  const ChatConversation({
    required this.id,
    required this.title,
    required this.messages,
    this.currentNode,
    this.nodes = const <String, ConversationNode>{},
    this.researchReports = const <ResearchReport>[],
  });

  final String id;
  final String title;
  final String? currentNode;
  final List<ChatMessage> messages;
  final Map<String, ConversationNode> nodes;
  final List<ResearchReport> researchReports;

  factory ChatConversation.fromJson(Map<String, dynamic> json) {
    final messageRaw = json['messages'];
    final nodeRaw = json['nodes'];
    final reportsRaw = json['research_reports'];
    final nodes = <String, ConversationNode>{};
    if (nodeRaw is Map) {
      for (final MapEntry<dynamic, dynamic> entry in nodeRaw.entries) {
        if (entry.value is Map) {
          final id = entry.key.toString();
          nodes[id] = ConversationNode.fromJson(
            id,
            (entry.value as Map).cast<String, dynamic>(),
          );
        }
      }
    }

    return ChatConversation(
      id: _string(json['id']) ?? _string(json['conversation_id']) ?? '',
      title: _string(json['title']) ?? 'New chat',
      currentNode: _string(json['current_node']),
      messages: messageRaw is List
          ? messageRaw
              .whereType<Map>()
              .map((Map item) => ChatMessage.fromJson(item.cast<String, dynamic>()))
              .where(
                (ChatMessage item) =>
                    item.text.isNotEmpty || item.assets.isNotEmpty || item.blocks.isNotEmpty,
              )
              .toList(growable: false)
          : const <ChatMessage>[],
      nodes: nodes,
      researchReports: reportsRaw is List
          ? reportsRaw
              .whereType<Map>()
              .map((Map item) => ResearchReport.fromJson(item.cast<String, dynamic>()))
              .toList(growable: false)
          : const <ResearchReport>[],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'current_node': currentNode,
        'messages': messages.map((ChatMessage item) => item.toJson()).toList(),
        'nodes': nodes.map(
          (String key, ConversationNode value) => MapEntry<String, dynamic>(key, value.toJson()),
        ),
        'research_reports': researchReports
            .map((ResearchReport item) => item.toJson())
            .toList(growable: false),
      };

  BranchPosition? branchPositionFor(ChatMessage message) {
    String? nodeId = message.nodeId;
    if (nodeId == null || nodeId.isEmpty) {
      for (final entry in nodes.entries) {
        if (entry.value.message?.id == message.id) {
          nodeId = entry.key;
          break;
        }
      }
    }
    if (nodeId == null || nodeId.isEmpty) {
      return null;
    }
    final node = nodes[nodeId];
    final parentId = node?.parent;
    if (parentId == null) {
      return null;
    }
    final siblings = nodes[parentId]?.children ?? const <String>[];
    if (siblings.length < 2) {
      return null;
    }
    final index = siblings.indexOf(nodeId);
    if (index < 0) {
      return null;
    }
    return BranchPosition(siblings: siblings, index: index);
  }
}

class BranchPosition {
  const BranchPosition({required this.siblings, required this.index});

  final List<String> siblings;
  final int index;

  bool get hasPrevious => index > 0;
  bool get hasNext => index + 1 < siblings.length;
  String? get previousNode => hasPrevious ? siblings[index - 1] : null;
  String? get nextNode => hasNext ? siblings[index + 1] : null;
}

class BridgeEvent {
  const BridgeEvent({required this.data, this.raw = ''});

  final Map<String, dynamic> data;
  final String raw;

  String? get type => _string(data['type']);
  String? get conversationId => _string(data['conversation_id']);

  ChatConversation? get conversation {
    final candidate = data['conversation'];
    if (candidate is Map) {
      return ChatConversation.fromJson(candidate.cast<String, dynamic>());
    }
    final nested = data['data'];
    if (nested is Map && nested['conversation'] is Map) {
      return ChatConversation.fromJson(
        (nested['conversation'] as Map).cast<String, dynamic>(),
      );
    }
    return null;
  }

  String get delta {
    if (type == 'message.delta') {
      return _string(data['text']) ?? '';
    }
    final direct = _string(data['delta']);
    if (direct != null) {
      return direct;
    }
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final first = (choices.first as Map).cast<String, dynamic>();
      final delta = first['delta'];
      if (delta is Map) {
        return _string(delta['content']) ?? '';
      }
    }
    return '';
  }
}

List<Map<String, dynamic>> _parseBlocks(dynamic value) {
  return value is List
      ? value
          .whereType<Map>()
          .map((Map item) => item.cast<String, dynamic>())
          .toList(growable: false)
      : const <Map<String, dynamic>>[];
}

List<ChatCitation> _parseCitations(dynamic value) {
  return value is List
      ? value
          .whereType<Map>()
          .map((Map item) => ChatCitation.fromJson(item.cast<String, dynamic>()))
          .toList(growable: false)
      : const <ChatCitation>[];
}

List<ChatAsset> _parseAssets(dynamic value) {
  return value is List
      ? value
          .whereType<Map>()
          .map((Map item) => ChatAsset.fromJson(item.cast<String, dynamic>()))
          .toList(growable: false)
      : const <ChatAsset>[];
}

List<ChatCitation> _citationsFromBlocks(List<Map<String, dynamic>> blocks) {
  final result = <ChatCitation>[];
  for (final block in blocks) {
    if (block['type'] != 'citations') {
      continue;
    }
    result.addAll(_parseCitations(block['items']));
  }
  return result;
}

List<ChatAsset> _assetsFromBlocks(List<Map<String, dynamic>> blocks) {
  final result = <ChatAsset>[];
  for (final block in blocks) {
    final type = _string(block['type']);
    if (type == 'image' || type == 'file') {
      result.add(ChatAsset.fromJson(block));
      continue;
    }
    final nested = block['assets'];
    if (nested is List) {
      for (final item in nested.whereType<Map>()) {
        result.add(ChatAsset.fromJson(item.cast<String, dynamic>()));
      }
    }
  }
  return result;
}

List<ChatCitation> _dedupeCitations(List<ChatCitation> items) {
  final seen = <String>{};
  final result = <ChatCitation>[];
  for (final item in items) {
    final key = '${item.url ?? ''}\u0000${item.title ?? ''}\u0000${item.text ?? ''}';
    if (seen.add(key)) {
      result.add(item);
    }
  }
  return List<ChatCitation>.unmodifiable(result);
}

List<ChatAsset> _dedupeAssets(List<ChatAsset> items) {
  final seen = <String>{};
  final result = <ChatAsset>[];
  for (final item in items) {
    final key = item.pointer ?? item.url ?? item.fileName ?? '';
    if (key.isEmpty || seen.add(key)) {
      result.add(item);
    }
  }
  return List<ChatAsset>.unmodifiable(result);
}

String? _string(dynamic value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

DateTime? _date(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).round(), isUtc: true).toLocal();
  }
  final text = _string(value);
  return text == null ? null : DateTime.tryParse(text)?.toLocal();
}

String _contentText(dynamic value) {
  if (value is String) {
    return value;
  }
  if (value is Map) {
    final parts = value['parts'];
    if (parts is List) {
      return parts.whereType<String>().join('\n');
    }
    final text = _string(value['text']);
    if (text != null) {
      return text;
    }
  }
  if (value is List) {
    return value.map((dynamic item) {
      if (item is String) {
        return item;
      }
      if (item is Map) {
        return _string(item['text']) ?? jsonEncode(item);
      }
      return item.toString();
    }).join('\n');
  }
  return '';
}
