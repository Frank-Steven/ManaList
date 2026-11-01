import 'dart:async';
import 'package:flutter/foundation.dart';

/// 一条错误记录。
class LogEntry {
  final DateTime at;
  final String scope;
  final String message;
  final String? stack;
  int repeats;

  LogEntry({
    required this.at,
    required this.scope,
    required this.message,
    this.stack,
    this.repeats = 1,
  });

  String get oneLine {
    final base = '${at.toIso8601String().substring(11, 19)} [$scope] $message';
    return repeats > 1 ? '$base（×$repeats）' : base;
  }
}

/// 轻量错误日志（P2-6）：替代 `catch (_) {}` 的静默吞异常。
///
/// 设计要点：
/// - 环形缓冲，只留最近 [capacity] 条，不占内存；
/// - 同 scope + 同 message 的重复错误只累加计数（流式解析每行失败时不会刷屏）；
/// - debug 下同时 print，方便 `flutter run` 直接看到；
/// - 设置页可查看/清空，用户不必再靠猜。
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int capacity = 50;

  final List<LogEntry> _entries = [];

  /// 最近 [capacity] 条，最新的在前。
  List<LogEntry> get entries => List.unmodifiable(_entries.reversed);

  int get count => _entries.length;

  LogEntry? get latest => _entries.isEmpty ? null : _entries.last;

  /// 记录一次失败。`scope` 用点分小写（如 `bridge.parse-file`）便于过滤。
  void warn(String scope, Object error, [StackTrace? stack]) {
    final message = error.toString();
    if (kDebugMode) {
      debugPrint('[$scope] $message');
    }
    // 去重：同 scope 同 message 只累加计数，避免高频失败刷屏
    for (final e in _entries) {
      if (e.scope == scope && e.message == message) {
        e.repeats++;
        notifyListeners();
        return;
      }
    }
    _entries.add(LogEntry(
      at: DateTime.now(),
      scope: scope,
      message: message.length > 300 ? '${message.substring(0, 300)}…' : message,
      stack: stack?.toString(),
    ));
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    _notifyThrottled();
  }

  /// 通知节流（2026-10-20 性能）：高频失败路径上每条都 notifyListeners 会带动
  /// 设置页/指示条重建；合并到 500ms 一次。
  Timer? _notifyTimer;

  void _notifyThrottled() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 500), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void clear() {
    _entries.clear();
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }
}
