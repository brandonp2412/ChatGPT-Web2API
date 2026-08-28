import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../api/bridge_client.dart';

class SecureStore {
  SecureStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  static const String _baseUrlKey = 'bridge.base_url';
  static const String _apiKeyKey = 'bridge.api_key';
  static const String _cacheKeyKey = 'cache.aes256_key';
  static const String _cacheFileName = 'chat_cache.v1.enc.json';

  final FlutterSecureStorage _secure;
  final Cipher _cipher = AesGcm.with256bits();

  Future<BridgeSettings> loadSettings() async {
    final baseUrl = await _secure.read(key: _baseUrlKey);
    final apiKey = await _secure.read(key: _apiKeyKey);
    return BridgeSettings(
      baseUrl: baseUrl?.trim().isNotEmpty == true
          ? baseUrl!.trim()
          : 'http://127.0.0.1:8080',
      apiKey: apiKey ?? '',
    );
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
    final file = await _cacheFile();
    if (!await file.exists()) {
      return null;
    }
    try {
      final envelope = jsonDecode(await file.readAsString());
      if (envelope is! Map) {
        throw const FormatException('Invalid encrypted cache envelope');
      }
      final map = envelope.cast<String, dynamic>();
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
    } on Object {
      // A cache is disposable. Corruption, an invalidated device key, or an
      // interrupted write must never prevent the app from starting.
      await file.delete().catchError((Object _) => file);
      return null;
    }
  }

  Future<void> writeCache(Map<String, dynamic> data) async {
    final clearBytes = utf8.encode(jsonEncode(data));
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
    await temp.writeAsString(jsonEncode(envelope), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
  }

  Future<void> clearCache() async {
    final file = await _cacheFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<SecretKey> _cacheKey() async {
    final existing = await _secure.read(key: _cacheKeyKey);
    if (existing != null && existing.isNotEmpty) {
      final bytes = base64Decode(existing);
      if (bytes.length == 32) {
        return SecretKey(bytes);
      }
    }
    final key = await _cipher.newSecretKey();
    final bytes = await key.extractBytes();
    await _secure.write(key: _cacheKeyKey, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  Future<File> _cacheFile() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}${Platform.pathSeparator}secure_cache');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}${Platform.pathSeparator}$_cacheFileName');
  }
}
