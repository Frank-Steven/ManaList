import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_log.dart';

/// 敏感凭据存储（P2-1）：API Key 与配对 token 不再明文躺在 SharedPreferences。
///
/// 抽象成接口有两个目的：
/// 1) 单测可注入内存实现（不依赖 Android Keystore）；
/// 2) 安全存储不可用时能降级并留痕，而不是让整个设置页崩掉。
abstract class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 生产实现：Android Keystore 加密（iOS 走 Keychain）。
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e, st) {
      AppLog.instance.warn('secret.read', e, st);
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e, st) {
      AppLog.instance.warn('secret.write', e, st);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e, st) {
      AppLog.instance.warn('secret.delete', e, st);
    }
  }
}

/// 内存实现（单测用）。
class InMemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
