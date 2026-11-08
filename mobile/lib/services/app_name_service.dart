import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

/// 应用不存在（平台侧 name_not_found 映射）——唯一记忆 null 的情形。
class AppNameNotFoundException implements Exception {
  final String packageName;
  const AppNameNotFoundException(this.packageName);

  @override
  String toString() => 'AppNameNotFoundException($packageName)';
}

/// 来源应用显示名懒解析（ux-fixes-2026-11 §2.1）。
///
/// 背景：采集期 `getApplicationLabel` 失败时旧代码把包名当应用名固化
/// 入库，鸿蒙等 ROM 上失败率高 → 消息流成片显示包名。现在采集失败存空，
/// 显示层对「空/等于包名」的名称经本服务重解析（平台通道 `getAppName`），
/// 成功后由调用方回填 DB，后续展示直接使用。
///
/// 与 AppIconService 同构：内存缓存 + inflight 合并 + 失败分类
/// （只有「包不存在」记忆 null，瞬时失败下次重试）。
class AppNameService {
  AppNameService._();

  static final AppNameService instance = AppNameService._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  /// packageName -> 显示名；null 表示已确认包不存在（不再重复查询）。
  final Map<String, String?> _mem = {};
  final Map<String, Future<String?>> _inflight = {};

  /// 测试注入：平台取名称；包不存在抛 [AppNameNotFoundException]。
  @visibleForTesting
  Future<String?> Function(String packageName)? fetcherOverride;

  /// 测试用：清空缓存与注入。
  @visibleForTesting
  void debugReset() {
    _mem.clear();
    _inflight.clear();
    fetcherOverride = null;
  }

  /// 该名称是否需要重解析：未设置 / 空白 / 被固化成了包名。
  static bool needsResolution(String? appName, String packageName) {
    final n = appName?.trim();
    return n == null || n.isEmpty || n == packageName;
  }

  String? cached(String packageName) => _mem[packageName];

  Future<String?> resolve(String packageName) {
    if (_mem.containsKey(packageName)) {
      return Future.value(_mem[packageName]);
    }
    final existing = _inflight[packageName];
    if (existing != null) return existing;
    final future = _resolve(packageName);
    _inflight[packageName] = future;
    unawaited(
        future.whenComplete(() => _inflight.remove(packageName)));
    return future;
  }

  Future<String?> _resolve(String packageName) async {
    try {
      final name = await (fetcherOverride ?? _fetchChannel)(packageName);
      final trimmed = name?.trim();
      if (trimmed != null && trimmed.isNotEmpty && trimmed != packageName) {
        return _mem[packageName] = trimmed;
      }
      // 空/等于包名：按瞬时处理，不记忆（下次重试）
      return null;
    } on AppNameNotFoundException {
      return _mem[packageName] = null;
    } catch (e, st) {
      AppLog.instance.warn('appname.resolve', e, st);
      return null;
    }
  }

  Future<String?> _fetchChannel(String packageName) async {
    try {
      return await _channel
          .invokeMethod<String>('getAppName', {'packageName': packageName});
    } on PlatformException catch (e) {
      if (e.code == 'name_not_found') {
        throw AppNameNotFoundException(packageName);
      }
      rethrow;
    }
  }
}
