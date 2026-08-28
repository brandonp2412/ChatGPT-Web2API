class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    this.memoryScope,
  });

  final String id;
  final String name;
  final String? memoryScope;

  factory ProjectSummary.fromJson(Map<String, dynamic> json) {
    return ProjectSummary(
      id: _string(json['id'] ?? json['gizmo_id']) ?? '',
      name: _string(json['name'] ?? json['title']) ?? 'Project',
      memoryScope: _string(json['memory_scope']),
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

String? _string(dynamic value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
