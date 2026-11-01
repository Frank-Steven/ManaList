import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'database.dart';
import '../services/app_log.dart';

/// Kotlin ↔ Dart 桥接：
/// - MethodChannel 负责通知监听授权检查/跳转、附件 deeplink 拉起；
/// - 通知数据不走 MethodChannel，Kotlin 的 NotificationListenerService 将每条
///   通知原子写入 filesDir/queue/<日期>/<uuid>.json，写完后立即通过 channel 通知
///   Dart 拉取（P3-3）；另有 20s 兜底轮询，覆盖应用被杀后重启的情况。
///   入库后删除文件。
class NotificationBridge {
  NotificationBridge._();

  static final NotificationBridge instance = NotificationBridge._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');
  /// 兜底轮询（P3-3）：Kotlin 采集服务写队列后会主动推 queueAvailable，
  /// 正常情况秒级可见；轮询只在应用重启/推送丢失时兜底，故放宽到 20 秒。
  static const _pollInterval = Duration(seconds: 20);
  static const _uuid = Uuid();

  final _onNewMessages = StreamController<int>.broadcast();

  /// 每次轮询到新通知时广播新入库条数。
  Stream<int> get onNewMessages => _onNewMessages.stream;

  Timer? _timer;
  bool _pulling = false;
  String? _queueDir;

  Future<bool> isListenerEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isNotificationListenerEnabled') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openListenerSettings() async {
    await _channel.invokeMethod<void>('openNotificationListenerSettings');
  }

  /// 本应用是否已加入电池优化白名单（v2.6 保活）。
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 弹「加入电池优化白名单」系统对话框（厂商阉割时回退到电池优化列表页）。
  Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 尝试跳转国产 ROM（vivo/小米/华为/OPPO/荣耀）自启动/后台管理页；
  /// 无已知组件可跳时返回 false（调用方给图文引导）。
  Future<bool> openAutoStartSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAutoStartSettings') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 本应用的系统应用详情页（通用回退入口）。
  Future<bool> openAppDetailsSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAppDetailsSettings') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---- 短信导入已随 v3 阶段 3 整体移除（design-v3 §3.2）----

  /// 打开附件访问方式（http 链接 / content:// / 应用 deeplink）。
  Future<bool> openDeeplink(String url) async {
    try {
      return await _channel
              .invokeMethod<bool>('openDeeplink', {'url': url}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String> _getQueueDir() async {
    final cached = _queueDir;
    if (cached != null) return cached;
    try {
      final dir = await _channel.invokeMethod<String>('getQueueDir');
      if (dir != null) {
        _queueDir = dir;
        return dir;
      }
    } on MissingPluginException {
      // 回退到应用私有 files 目录（Android 上即 filesDir）
    }
    final supportDir = await getApplicationSupportDirectory();
    final dir = '${supportDir.path}/queue';
    _queueDir = dir;
    return dir;
  }

  void startPolling() {
    _installQueueCallback();
    _timer ??= Timer.periodic(_pollInterval, (_) => pullOnce());
    // 启动时立即拉一次
    unawaited(pullOnce());
  }

  /// 安装「队列有新数据」回调（P3-3）：采集服务写完文件会调
  /// `queueAvailable`，此时立刻取一次，不必等兜底轮询。
  void _installQueueCallback() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'queueAvailable') {
        unawaited(pullOnce());
      }
      return null;
    });
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// 读取队列文件并入库，返回新入库条数。
  bool _pullPending = false;

  Future<int> pullOnce() async {
    if (_pulling) {
      // 正在拉取时又来了 queueAvailable：记一笔，本轮结束后立刻补拉，
      // 否则这批通知要等 20s 兜底轮询（子代理审查指出）。
      _pullPending = true;
      return 0;
    }
    _pulling = true;
    try {
      final root = Directory(await _getQueueDir());
      if (!await root.exists()) return 0;

      // O03（2026-10-21）：先把本轮所有队列文件解析成 Message，再**一次事务
      // 批量入库**。原来每个文件一次 insertMessageIfNew（查重 + 插入，各自隐式
      // 事务），通知密集时是 N 次 SQL 往返 + N 次事务提交。
      // 注意：文件读取顺序即插入顺序（与改动前一致），每条消息的 postedTime
      // 由它自己的文件携带，不会因为合并而丢失或错乱。
      final pending = <Message>[];
      final sources = <File>[]; // 与 pending 一一对应的源文件
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final map =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          pending.add(_fromQueueEntry(map));
          sources.add(entity);
        } catch (e, st) {
          AppLog.instance.warn('bridge.parse-file', e, st);
          // 单个文件损坏不阻塞其他文件，文件照删避免反复失败（与改动前一致）
          try {
            await entity.delete();
          } catch (e, st) { AppLog.instance.warn('bridge.delete-file', e, st); }
        }
      }

      var imported = 0;
      if (pending.isNotEmpty) {
        try {
          imported = await AppDatabase.instance.insertMessagesIfNew(pending);
        } catch (e, st) {
          // 入库失败：**保留**队列文件留给下一轮重试。
          // （改动前是 finally 里无条件删文件，写库失败就等于丢消息）
          AppLog.instance.warn('bridge.insert-batch', e, st);
          sources.clear();
        }
        for (final f in sources) {
          try {
            await f.delete();
          } catch (e, st) { AppLog.instance.warn('bridge.delete-file', e, st); }
        }
      }

      // 清理空日期目录
      await for (final entity in root.list()) {
        if (entity is Directory) {
          try {
            if (await entity.list().isEmpty) await entity.delete();
          } catch (e, st) { AppLog.instance.warn('bridge.cleanup-dir', e, st); }
        }
      }

      if (imported > 0) _onNewMessages.add(imported);
      return imported;
    } catch (e, st) {
      AppLog.instance.warn('bridge.drain', e, st);
      return 0;
    } finally {
      _pulling = false;
      if (_pullPending) {
        _pullPending = false;
        unawaited(pullOnce());
      }
    }
  }

  /// 队列文件（Kotlin 通知监听器落盘）→ v2 Message（captureType=notification）。
  Message _fromQueueEntry(Map<String, dynamic> map) {
    final packageName = map['packageName'] as String? ?? 'unknown';
    final title = map['title'] as String? ?? '';
    final body = map['text'] as String? ?? '';
    final postedAt = (map['postedTime'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: _uuid.v4(),
      packageName: packageName,
      appName: map['appName'] as String?,
      channelId: map['channelId'] as String?,
      conversationTitle: map['conversationTitle'] as String?,
      sender: map['sender'] as String?,
      title: title,
      body: body,
      postedAt: postedAt,
      captureType: 'notification',
      contentHash: computeContentHash(packageName, title, body, postedAt),
      status: MessageStatus.pending,
      priority: MessagePriority.none,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
