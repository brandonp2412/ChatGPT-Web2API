import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sloppa/src/api/bridge_client.dart';
import 'package:sloppa/src/storage/secure_store.dart';

class _MemorySecureStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

void main() {
  late Directory temp;
  late _MemorySecureStore keys;
  late SecureStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sloppa-cache-test-');
    keys = _MemorySecureStore();
    store = SecureStore(
      secureStorage: keys,
      supportDirectoryProvider: () async => temp,
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('encrypted cache round-trips without plaintext on disk', () async {
    const secretText = 'the confidential chat payload 123456789';
    await store.writeCache(<String, dynamic>{
      'conversation': secretText,
      'nested': <String, dynamic>{'message': 'also secret'},
    });

    final file = File(
      '${temp.path}${Platform.pathSeparator}secure_cache'
      '${Platform.pathSeparator}chat_cache.v1.enc.json',
    );
    expect(await file.exists(), isTrue);
    final onDisk = await file.readAsString();
    expect(onDisk, isNot(contains(secretText)));
    expect(onDisk, isNot(contains('also secret')));
    expect(onDisk, contains('ciphertext'));
    expect(keys.values['cache.aes256_key'], isNotNull);

    final decoded = await store.readCache();
    expect(decoded?['conversation'], secretText);
    expect((decoded?['nested'] as Map)['message'], 'also secret');
  });

  test('serialized writes make the latest submitted snapshot win', () async {
    final writes = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      writes.add(store.writeCache(<String, dynamic>{'revision': i}));
    }
    await Future.wait(writes);

    expect((await store.readCache())?['revision'], 19);
  });

  test('corrupt cache is discarded and never prevents startup', () async {
    await store.writeCache(<String, dynamic>{'message': 'valid'});
    final file = File(
      '${temp.path}${Platform.pathSeparator}secure_cache'
      '${Platform.pathSeparator}chat_cache.v1.enc.json',
    );
    await file.writeAsString('{"version":1,"ciphertext":"broken"}', flush: true);

    expect(await store.readCache(), isNull);
    expect(await file.exists(), isFalse);
  });

  test('bridge URL and bearer key are kept out of encrypted cache payload', () async {
    await store.saveSettings(
      const BridgeSettings(
        baseUrl: 'https://bridge.example/api',
        apiKey: 'super-sensitive-bearer',
      ),
    );
    await store.writeCache(<String, dynamic>{'conversation': 'hello'});

    final file = File(
      '${temp.path}${Platform.pathSeparator}secure_cache'
      '${Platform.pathSeparator}chat_cache.v1.enc.json',
    );
    final onDisk = await file.readAsString();
    expect(onDisk, isNot(contains('super-sensitive-bearer')));
    expect(onDisk, isNot(contains('bridge.example')));
    expect(keys.values['bridge.api_key'], 'super-sensitive-bearer');
    expect(keys.values['bridge.base_url'], 'https://bridge.example/api');
  });

  test('clearCache removes current and staging files', () async {
    await store.writeCache(<String, dynamic>{'conversation': 'hello'});
    await store.clearCache();

    final directory = Directory(
      '${temp.path}${Platform.pathSeparator}secure_cache',
    );
    final names = await directory.exists()
        ? await directory
            .list()
            .map((FileSystemEntity item) => item.path)
            .toList()
        : <String>[];
    expect(
      names.where((String path) => path.contains('chat_cache.v1.enc.json')),
      isEmpty,
    );
  });
}
