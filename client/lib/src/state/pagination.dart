typedef OffsetPageLoader<T> = Future<List<T>> Function(int offset, int limit);
typedef CursorPageLoader<T> = Future<CursorPage<T>> Function(String cursor);

class CursorPage<T> {
  const CursorPage({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}

/// Collect every offset-based page without imposing an arbitrary page ceiling.
///
/// A backend bug that repeats the same full page cannot loop forever: requests
/// stop when a page contributes no new IDs. Offsets still advance by the raw
/// page length so occasional duplicate records do not shift later pages.
Future<List<T>> collectOffsetPages<T>({
  required OffsetPageLoader<T> loadPage,
  required String Function(T item) idOf,
  int pageSize = 100,
}) async {
  if (pageSize <= 0) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
  }

  final result = <T>[];
  final seenIds = <String>{};
  var offset = 0;

  while (true) {
    final page = await loadPage(offset, pageSize);
    var added = 0;
    for (final item in page) {
      final id = idOf(item);
      if (id.isEmpty || !seenIds.add(id)) {
        continue;
      }
      result.add(item);
      added++;
    }

    if (page.length < pageSize || page.isEmpty || added == 0) {
      break;
    }
    offset += page.length;
  }

  return result;
}

/// Collect every cursor-based page while refusing cursor cycles.
Future<List<T>> collectCursorPages<T>({
  required CursorPageLoader<T> loadPage,
  required String Function(T item) idOf,
  String initialCursor = '0',
}) async {
  final result = <T>[];
  final seenIds = <String>{};
  final seenCursors = <String>{};
  var cursor = initialCursor;

  while (seenCursors.add(cursor)) {
    final page = await loadPage(cursor);
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
