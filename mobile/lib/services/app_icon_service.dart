import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_log.dart';

/// 应用不存在（平台侧 NameNotFoundException 映射）——只有这种情况
/// 才把 null 记忆进缓存（ux-fixes-2026-11 §1.2-3）；瞬时失败不记忆。
class AppIconNotFoundException implements Exception {
  final String packageName;
  const AppIconNotFoundException(this.packageName);

  @override
  String toString() => 'AppIconNotFoundException($packageName)';
}

typedef IconFetcher = Future<Uint8List?> Function(String packageName);

/// 应用图标加载：平台通道从 PackageManager 取 PNG（96px），
/// 内存 + 磁盘双层缓存。磁盘缓存放持久目录
/// （<supportDir>/app_icons/<包名>.png）——早期放在临时目录，
/// 系统随时清理导致每次启动都重新走通道，2026-11-01 起迁移，
/// 旧临时目录缓存仍作回退读取一次。
///
/// 2026-11-08 修复（ux-fixes-2026-11 §1）：
/// - [cached] 同步快路径：build 时内存命中即当帧渲染，消除首屏空白；
/// - 失败分类：只有「包不存在」记忆 null；通道/IO 瞬时失败不记忆，
///   下次访问自然重试（此前任何异常都被永久记忆为「无图标」）；
/// - 磁盘写失败不影响已取到的字节返回（此前被外层 catch 吞成 null）；
/// - [prewarm] 批量预热：磁盘先读，未命中的一次通道调用批量取回。
class AppIconService {
  AppIconService._();

  static final AppIconService instance = AppIconService._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  /// packageName -> PNG 字节；null 表示已确认应用不存在（不再重复查询）。
  final Map<String, Uint8List?> _mem = {};

  /// 正在进行的磁盘/通道加载合并（避免滚动列表并发重复触发）。
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// 测试注入：磁盘读（无缓存返回 null）。
  @visibleForTesting
  IconFetcher? diskReaderOverride;

  /// 测试注入：通道取单个图标；应用不存在抛 [AppIconNotFoundException]。
  @visibleForTesting
  IconFetcher? channelFetcherOverride;

  /// 测试注入：批量取图标（返回 pkg → 字节，失败的缺席）。
  @visibleForTesting
  Future<Map<String, Uint8List>> Function(List<String> packages)?
      batchFetcherOverride;

  /// 测试注入：磁盘写。
  @visibleForTesting
  Future<void> Function(String packageName, Uint8List bytes)?
      diskWriterOverride;

  /// 测试用：清空全部缓存与注入。
  @visibleForTesting
  void debugReset() {
    _mem.clear();
    _inflight.clear();
    diskReaderOverride = null;
    channelFetcherOverride = null;
    batchFetcherOverride = null;
    diskWriterOverride = null;
  }

  /// 同步快路径：内存命中即返回（含已确认的 null），未命中返回 null 且
  /// 调用方应走 [iconFor] 异步加载。用 [hasCached] 区分「未缓存」与
  /// 「已确认无图标」。
  Uint8List? cached(String packageName) => _mem[packageName];

  bool hasCached(String packageName) => _mem.containsKey(packageName);

  Future<Uint8List?> iconFor(String packageName) {
    if (_mem.containsKey(packageName)) {
      return Future.value(_mem[packageName]);
    }
    final existing = _inflight[packageName];
    if (existing != null) return existing;
    final future = _load(packageName);
    _inflight[packageName] = future;
    // 清理回调单独挂，不作为返回值（调用方拿到的是原始加载 Future）
    unawaited(
        future.whenComplete(() => _inflight.remove(packageName)));
    return future;
  }

  /// 批量预热（首屏组头）：磁盘命中的直接进内存表；其余一次通道批量取回。
  /// 批量通道不可用时回退逐条 [iconFor]。全部 best-effort，不抛异常。
  Future<void> prewarm(Iterable<String> packages) async {
    final missing = packages
        .where((p) => !_mem.containsKey(p) && !_inflight.containsKey(p))
        .toSet()
        .toList();
    if (missing.isEmpty) return;

    final needChannel = <String>[];
    for (final pkg in missing) {
      try {
        final bytes = await (diskReaderOverride ?? _readDisk)(pkg);
        if (bytes != null && bytes.isNotEmpty) {
          _mem[pkg] = bytes;
          continue;
        }
      } catch (e, st) {
        AppLog.instance.warn('icon.prewarm-disk', e, st);
      }
      needChannel.add(pkg);
    }
    if (needChannel.isEmpty) return;

    try {
      final fetched = await (batchFetcherOverride ?? _fetchBatch)(needChannel);
      for (final entry in fetched.entries) {
        _mem[entry.key] = entry.value;
        try {
          await (diskWriterOverride ?? _writeDisk)(entry.key, entry.value);
        } catch (e, st) {
          AppLog.instance.warn('icon.prewarm-write', e, st);
        }
      }
    } catch (e, st) {
      // 批量通道不可用（旧原生/测试环境）：回退逐条加载
      AppLog.instance.warn('icon.prewarm-batch', e, st);
      await Future.wait(needChannel.map(iconFor));
    }
  }

  Future<Uint8List?> _load(String packageName) async {
    // 1. 磁盘缓存（读失败不阻断，继续走通道）
    try {
      final bytes = await (diskReaderOverride ?? _readDisk)(packageName);
      if (bytes != null && bytes.isNotEmpty) {
        return _mem[packageName] = bytes;
      }
    } catch (e, st) {
      AppLog.instance.warn('icon.disk-read', e, st);
    }
    // 2. 平台通道
    try {
      final bytes =
          await (channelFetcherOverride ?? _fetchChannel)(packageName);
      if (bytes != null && bytes.isNotEmpty) {
        // 3. 写磁盘 best-effort：失败不影响返回已取到的字节
        try {
          await (diskWriterOverride ?? _writeDisk)(packageName, bytes);
        } catch (e, st) {
          AppLog.instance.warn('icon.disk-write', e, st);
        }
        return _mem[packageName] = bytes;
      }
      // 通道返回空：按瞬时处理，不记忆
      return null;
    } on AppIconNotFoundException {
      // 应用已卸载/不存在：唯一记忆 null 的情形
      return _mem[packageName] = null;
    } catch (e, st) {
      // 瞬时失败（通道异常/线程失败）：不记忆，下次访问重试
      AppLog.instance.warn('icon.fetch', e, st);
      return null;
    }
  }

  // ---- 默认实现（生产路径） ----

  Future<Uint8List?> _readDisk(String packageName) async {
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
          return bytes;
        }
      }
    }
    return null;
  }

  Future<Uint8List?> _fetchChannel(String packageName) async {
    try {
      return await _channel
          .invokeMethod<Uint8List>('getAppIcon', {'packageName': packageName});
    } on PlatformException catch (e) {
      if (e.code == 'icon_not_found') {
        throw AppIconNotFoundException(packageName);
      }
      rethrow;
    }
  }

  Future<Map<String, Uint8List>> _fetchBatch(List<String> packages) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getAppIcons', {'packages': packages});
    final map = <String, Uint8List>{};
    result?.forEach((key, value) {
      if (key is String && value is Uint8List && value.isNotEmpty) {
        map[key] = value;
      }
    });
    return map;
  }

  Future<void> _writeDisk(String packageName, Uint8List bytes) async {
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/app_icons/$packageName.png');
    await file.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }
}
