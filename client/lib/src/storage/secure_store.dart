import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../api/bridge_client.dart';
import '../logging/app_logger.dart';
import '../config.dart';

typedef SupportDirectoryProvider = Future<Directory> Function();

abstract interface class SecureKeyValueStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

class SecureStore {
  SecureStore({
    SecureKeyValueStore? secureStorage,
    SupportDirectoryProvider? supportDirectoryProvider,
  }) : _secure = secureStorage ?? FlutterSecureKeyValueStore(),
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const String _baseUrlKey = 'bridge.base_url';
  static const String _apiKeyKey = 'bridge.api_key';
  static const String _cacheKeyKey = 'cache.aes256_key';
  static const String _cacheFileName = 'chat_cache.v1.enc.json';

  final SecureKeyValueStore _secure;
  final SupportDirectoryProvider _supportDirectoryProvider;
  final Cipher _cipher = AesGcm.with256bits();
  Future<void> _writeTail = Future<void>.value();

  bool get _linuxKeychainUnavailable =>
      !kIsWeb && Platform.isLinux && _secure is FlutterSecureKeyValueStore;

  bool get _fileCacheUnavailable => kIsWeb || _linuxKeychainUnavailable;

  Future<BridgeSettings> loadSettings() async {
    if (kIsWeb) {
      appLogger.debug(
        'SecureStore: web secure storage is unavailable during startup; using defaults',
      );
      return const BridgeSettings(baseUrl: defaultBridgeUrl);
    }
    if (_linuxKeychainUnavailable) {
      appLogger.warning(
        'SecureStore: Linux keychain unavailable in this session; using default bridge settings',
      );
      return const BridgeSettings(baseUrl: defaultBridgeUrl);
    }
    appLogger.debug('SecureStore: reading bridge.base_url');
    final baseUrl = await _readWithTimeout(_baseUrlKey);
    appLogger.debug('SecureStore: reading bridge.api_key');
    final apiKey = await _readWithTimeout(_apiKeyKey);
    appLogger.debug('SecureStore: settings read complete');
    return BridgeSettings(
      baseUrl: baseUrl?.trim().isNotEmpty == true
          ? baseUrl!.trim()
          : defaultBridgeUrl,
      apiKey: apiKey ?? '',
    );
  }

  Future<String?> _readWithTimeout(String key) async {
    try {
      return await _secure.read(key: key).timeout(const Duration(seconds: 3));
    } on Object catch (error, stackTrace) {
      appLogger.handle(
        error,
        stackTrace,
        'SecureStore: read failed/timed out for $key; using default',
      );
      return null;
    }
  }

  Future<void> saveSettings(BridgeSettings settings) async {
    final validation = BridgeSettings.validateBaseUrl(settings.baseUrl);
    if (validation != null) {
      throw ArgumentError(validation);
    }
    await _secure.write(
      key: _baseUrlKey,
      value: BridgeSettings.normalizedBaseUrl(settings.baseUrl),
    );
    if (settings.apiKey.trim().isEmpty) {
      await _secure.delete(key: _apiKeyKey);
    } else {
      await _secure.write(key: _apiKeyKey, value: settings.apiKey.trim());
    }
  }

  Future<Map<String, dynamic>?> readCache() async {
    if (_fileCacheUnavailable) {
      appLogger.debug(
        kIsWeb
            ? 'SecureStore: file cache is unavailable on web; skipping restore'
            : 'SecureStore: skipping encrypted cache on Linux without keychain',
      );
      return null;
    }
    appLogger.debug('SecureStore: waiting for cache writes');
    await _writeTail;
    final file = await _cacheFile();
    appLogger.debug('SecureStore: checking cache ${file.path}');
    if (!await file.exists()) {
      appLogger.debug('SecureStore: cache absent');
      return null;
    }
    try {
      final envelope = jsonDecode(await file.readAsString());
      if (envelope is! Map) {
        throw const FormatException('Invalid encrypted cache envelope');
      }
      final map = envelope.cast<String, dynamic>();
      if (map['version'] != 1) {
        throw const FormatException('Unsupported encrypted cache version');
      }
      final nonce = base64Decode((map['nonce'] ?? '').toString());
      final cipherText = base64Decode((map['ciphertext'] ?? '').toString());
      final mac = Mac(base64Decode((map['mac'] ?? '').toString()));
      final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
      final clearBytes = await _cipher.decrypt(
        secretBox,
        secretKey: await _cacheKey(),
      );
      final decoded = jsonDecode(utf8.decode(clearBytes));
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } on Object catch (error, stackTrace) {
      appLogger.handle(
        error,
        stackTrace,
        'SecureStore: cache invalid; deleting',
      );
      // A cache is disposable. Corruption, an invalidated device key, or an
      // interrupted write must never prevent the app from starting.
      await _deleteBestEffort(file);
      return null;
    }
  }

  Future<void> writeCache(Map<String, dynamic> data) {
    if (_fileCacheUnavailable) {
      appLogger.debug(
        kIsWeb
            ? 'SecureStore: file cache is unavailable on web; skipping write'
            : 'SecureStore: skipping encrypted cache write on Linux without keychain',
      );
      return Future<void>.value();
    }
    // Snapshot before queueing: callers may mutate their state while another
    // encrypted write is in flight.
    final encoded = jsonEncode(data);
    final operation = _writeTail.then((_) => _writeEncodedCache(encoded));
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _writeEncodedCache(String encoded) async {
    final clearBytes = utf8.encode(encoded);
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      clearBytes,
      secretKey: await _cacheKey(),
      nonce: nonce,
    );
    final envelope = <String, dynamic>{
      'version': 1,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };

    final file = await _cacheFile();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await _deleteBestEffort(temp);
    await _deleteBestEffort(backup);
    await temp.writeAsString(jsonEncode(envelope), flush: true);

    var movedOriginal = false;
    try {
      if (await file.exists()) {
        await file.rename(backup.path);
        movedOriginal = true;
      }
      await temp.rename(file.path);
      await _deleteBestEffort(backup);
    } catch (error, stackTrace) {
      appLogger.error(
        'SecureStore: atomic cache replacement failed; attempting rollback',
        error,
        stackTrace,
      );
      if (!await file.exists() && movedOriginal && await backup.exists()) {
        try {
          await backup.rename(file.path);
        } on FileSystemException {
          // The cache is disposable; preserve the original exception below.
        }
      }
      rethrow;
    } finally {
      await _deleteBestEffort(temp);
      if (await file.exists()) {
        await _deleteBestEffort(backup);
      }
    }
  }

  Future<void> clearCache() async {
    if (_fileCacheUnavailable) {
      return;
    }
    await _writeTail;
    final file = await _cacheFile();
    await _deleteBestEffort(file);
    await _deleteBestEffort(File('${file.path}.tmp'));
    await _deleteBestEffort(File('${file.path}.bak'));
  }

  Future<SecretKey> _cacheKey() async {
    final existing = await _secure.read(key: _cacheKeyKey);
    if (existing != null && existing.isNotEmpty) {
      try {
        final bytes = base64Decode(existing);
        if (bytes.length == 32) {
          return SecretKey(bytes);
        }
      } on FormatException {
        // Replace malformed key material with a fresh device-protected key.
      }
    }
    final key = await _cipher.newSecretKey();
    final bytes = await key.extractBytes();
    await _secure.write(key: _cacheKeyKey, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  Future<File> _cacheFile() async {
    final root = await _supportDirectoryProvider();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}secure_cache',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}${Platform.pathSeparator}$_cacheFileName');
  }

  Future<void> _deleteBestEffort(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Cache cleanup is best effort and must not take the app down.
    }
  }
}
