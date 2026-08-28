typedef OffsetPageLoader<T> = Future<List<T>> Function(int offset, int limit);
typedef CursorPageLoader<T> = Future<CursorPage<T>> Function(String cursor);

class CursorPage<T> {
  const CursorPage({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}

/// Collect every offset-based page without imposing an arbitrary page ceiling.
///
/// Overlapping pages are allowed. A backend that ignores offsets and repeats a
/// full page is detected by a stable page signature rather than by an arbitrary
/// maximum page count.
Future<List<T>> collectOffsetPages<T>({
  required OffsetPageLoader<T> loadPage,
  required String Function(T item) idOf,
  int pageSize = 100,
  int initialOffset = 0,
}) async {
  if (pageSize <= 0) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
  }
  if (initialOffset < 0) {
    throw ArgumentError.value(initialOffset, 'initialOffset', 'must be non-negative');
  }

  final result = <T>[];
  final seenIds = <String>{};
  final seenPages = <String>{};
  var offset = initialOffset;

  while (true) {
    final page = await loadPage(offset, pageSize);
    if (page.isEmpty) {
      break;
    }

    final signatureIds = page.map(idOf).where((String id) => id.isNotEmpty).toList()
      ..sort();
    final signature = '${page.length}\u0000${signatureIds.join('\u0001')}';
    if (!seenPages.add(signature)) {
      break;
    }

    for (final item in page) {
      final id = idOf(item);
      if (id.isNotEmpty && seenIds.add(id)) {
        result.add(item);
      }
    }

    if (page.length < pageSize) {
      break;
    }
    offset += page.length;
  }

  return result;
}

/// Collect every cursor-based page while refusing cursor or repeated-page cycles.
Future<List<T>> collectCursorPages<T>({
  required CursorPageLoader<T> loadPage,
  required String Function(T item) idOf,
  String initialCursor = '0',
}) async {
  final result = <T>[];
  final seenIds = <String>{};
  final seenCursors = <String>{};
  final seenPages = <String>{};
  var cursor = initialCursor;

  while (seenCursors.add(cursor)) {
    final page = await loadPage(cursor);
    final signatureIds =
        page.items.map(idOf).where((String id) => id.isNotEmpty).toList()..sort();
    final signature = '${page.items.length}\u0000${signatureIds.join('\u0001')}';
    if (!seenPages.add(signature) && page.items.isNotEmpty) {
      break;
    }

    for (final item in page.items) {
      final id = idOf(item);
      if (id.isNotEmpty && seenIds.add(id)) {
        result.add(item);
      }
    }

    final next = page.nextCursor?.trim();
    if (next == null || next.isEmpty || next == cursor) {
      break;
    }
    cursor = next;
  }

  return result;
}
