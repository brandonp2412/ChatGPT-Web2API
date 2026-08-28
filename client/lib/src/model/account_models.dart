class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    this.memoryScope,
    this.instructions,
  });

  final String id;
  final String name;
  final String? memoryScope;
  final String? instructions;

  factory ProjectSummary.fromJson(Map<String, dynamic> json) {
    return ProjectSummary(
      id: _string(json['id'] ?? json['gizmo_id']) ?? '',
      name: _string(json['name'] ?? json['title']) ?? 'Project',
      memoryScope: _string(json['memory_scope']),
      instructions: _string(json['instructions']),
    );
  }
}

class ProjectFile {
  const ProjectFile({
    required this.id,
    required this.name,
    this.mimeType,
    this.size,
  });

  final String id;
  final String name;
  final String? mimeType;
  final int? size;

  factory ProjectFile.fromJson(Map<String, dynamic> json) {
    final rawSize = json['size'] ?? json['file_size'] ?? json['file_size_bytes'];
    return ProjectFile(
      id: _string(json['id'] ?? json['file_id']) ?? '',
      name: _string(json['name'] ?? json['file_name']) ?? 'File',
      mimeType: _string(json['mime_type'] ?? json['mimeType']),
      size: rawSize is num ? rawSize.toInt() : null,
    );
  }
}

class GptSummary {
  const GptSummary({
    required this.id,
    required this.name,
    this.description,
  });

  final String id;
  final String name;
  final String? description;

  factory GptSummary.fromJson(Map<String, dynamic> json) {
    return GptSummary(
      id: _string(json['id'] ?? json['gizmo_id']) ?? '',
      name: _string(json['name'] ?? json['title']) ?? 'GPT',
      description: _string(json['description'] ?? json['short_description']),
    );
  }
}

class LibraryItem {
  const LibraryItem({required this.name, this.detail});

  final String name;
  final String? detail;

  factory LibraryItem.fromJson(Map<String, dynamic> json) {
    return LibraryItem(
      name: _string(json['name']) ?? '',
      detail: _string(json['detail']),
    );
  }
}

class InteractiveAction {
  const InteractiveAction({required this.label, this.testId});

  final String label;
  final String? testId;

  factory InteractiveAction.fromJson(Map<String, dynamic> json) {
    return InteractiveAction(
      label: _string(json['label']) ?? '',
      testId: _string(json['testid']),
    );
  }
}

class MemoryItem {
  const MemoryItem({required this.id, required this.content});

  final String id;
  final String content;

  factory MemoryItem.fromJson(Map<String, dynamic> json) {
    return MemoryItem(
      id: _string(json['id'] ?? json['memory_id']) ?? '',
      content: _string(json['content'] ?? json['text'] ?? json['memory']) ?? '',
    );
  }
}

class ShareResult {
  const ShareResult({required this.id, this.url});

  final String id;
  final String? url;

  factory ShareResult.fromJson(Map<String, dynamic> json) {
    return ShareResult(
      id: _string(json['id'] ?? json['share_id']) ?? '',
      url: _string(json['url'] ?? json['share_url'] ?? json['public_url']),
    );
  }
}

String? _string(dynamic value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
