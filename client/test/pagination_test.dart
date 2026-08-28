import 'package:flutter_test/flutter_test.dart';
import 'package:sloppa/src/state/pagination.dart';

void main() {
  test('offset pagination loads beyond the old 2000 item ceiling', () async {
    const total = 2505;
    var calls = 0;

    final result = await collectOffsetPages<String>(
      pageSize: 100,
      loadPage: (int offset, int limit) async {
        calls++;
        if (offset >= total) {
          return const <String>[];
        }
        final candidate = offset + limit;
        final end = candidate < total ? candidate : total;
        return List<String>.generate(
          end - offset,
          (int i) => '${offset + i}',
        );
      },
      idOf: (String item) => item,
    );

    expect(result, hasLength(total));
    expect(result.first, '0');
    expect(result.last, '2504');
    expect(calls, 26);
  });

  test('offset pagination stops when a backend repeats a full page', () async {
    var calls = 0;

    final result = await collectOffsetPages<String>(
      pageSize: 2,
      loadPage: (int offset, int limit) async {
        calls++;
        return const <String>['a', 'b'];
      },
      idOf: (String item) => item,
    );

    expect(result, <String>['a', 'b']);
    expect(calls, 2);
  });

  test('cursor pagination follows every cursor and de-duplicates items', () async {
    final requested = <String>[];
    final pages = <String, CursorPage<String>>{
      '0': const CursorPage<String>(
        items: <String>['a', 'b'],
        nextCursor: 'c1',
      ),
      'c1': const CursorPage<String>(
        items: <String>['b', 'c'],
        nextCursor: 'c2',
      ),
      'c2': const CursorPage<String>(items: <String>['d']),
    };

    final result = await collectCursorPages<String>(
      loadPage: (String cursor) async {
        requested.add(cursor);
        return pages[cursor]!;
      },
      idOf: (String item) => item,
    );

    expect(result, <String>['a', 'b', 'c', 'd']);
    expect(requested, <String>['0', 'c1', 'c2']);
  });

  test('cursor pagination refuses a cursor cycle', () async {
    var calls = 0;

    final result = await collectCursorPages<String>(
      loadPage: (String cursor) async {
        calls++;
        return CursorPage<String>(
          items: <String>['item-$cursor'],
          nextCursor: cursor == '0' ? 'c1' : '0',
        );
      },
      idOf: (String item) => item,
    );

    expect(result, <String>['item-0', 'item-c1']);
    expect(calls, 2);
  });

  test('offset pagination rejects invalid page size', () async {
    expect(
      () => collectOffsetPages<String>(
        pageSize: 0,
        loadPage: (int offset, int limit) async => const <String>[],
        idOf: (String item) => item,
      ),
      throwsArgumentError,
    );
  });
}
