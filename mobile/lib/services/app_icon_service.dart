import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_log.dart';

/// 应用图标加载（v2.4）：平台通道从 PackageManager 取 PNG（96px），
/// 内存 + 磁盘双层缓存。磁盘缓存放持久目录
/// （<supportDir>/app_icons/<包名>.png）——早期放在临时目录，
/// 系统随时清理导致每次启动都重新走通道，2026-11-01 起迁移，
/// 旧临时目录缓存仍作回退读取一次。
/// 应用已卸载/查询失败返回 null，调用方显示占位。
class AppIconService {
  AppIconService._();

  static final AppIconService instance = AppIconService._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  /// packageName -> PNG 字节；null 表示已确认无图标（不再重复查询）。
  final Map<String, Uint8List?> _mem = {};

  /// 正在进行的磁盘/通道加载合并（避免滚动列表并发重复触发）。
  final Map<String, Future<Uint8List?>> _inflight = {};

  Future<Uint8List?> iconFor(String packageName) {
    if (_mem.containsKey(packageName)) {
      return Future.value(_mem[packageName]);
    }
    return _inflight.putIfAbsent(
      packageName,
      () => _load(packageName).whenComplete(() => _inflight.remove(packageName)),
    );
  }

  Future<Uint8List?> _load(String packageName) async {
    try {
      final support = await getApplicationSupportDirectory();
      final file = File('${support.path}/app_icons/$packageName.png');
      for (final candidate in [
        file,
        // 旧临时目录缓存回退（迁移期兼容，命中后写入持久目录）
        File('${(await getTemporaryDirectory()).path}/app_icons/'
            '$packageName.png'),
      ]) {
        if (await candidate.exists()) {
          final bytes = await candidate.readAsBytes();
          if (bytes.isNotEmpty) {
            if (candidate.path != file.path) {
              await file.create(recursive: true);
              await file.writeAsBytes(bytes, flush: true);
            }
            return _mem[packageName] = bytes;
          }
        }
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
          'getAppIcon', {'packageName': packageName});
      if (bytes != null && bytes.isNotEmpty) {
        await file.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return _mem[packageName] = bytes;
      }
    } catch (e, st) {
      AppLog.instance.warn('icon.cache-write', e, st);
      // 图标是锦上添花，失败静默
    }
    return _mem[packageName] = null;
  }
}
