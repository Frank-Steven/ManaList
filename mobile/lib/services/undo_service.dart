import 'dart:async';

import 'package:uuid/uuid.dart';

/// 撤销队列条目（设计 §6）。逆操作闭包由 register 时提供，不对外暴露。
class UndoEntry {
  final String id;
  final String label;
  final DateTime enqueuedAt;

  const UndoEntry({
    required this.id,
    required this.label,
    required this.enqueuedAt,
  });
}

/// 撤销服务：纯内存单例，不落盘（重启后队列清空可接受，撤销窗口只有 10 秒）。
///
/// 栈语义：后来者先撤；被撤销项永久移除不做重做；撤销后再入队即天然
/// 截断分叉（撤销只弹栈、入队即截断，满足"分叉丢弃另一分支"）。
class UndoService {
  UndoService._();

  static final UndoService instance = UndoService._();

  static const _ttl = Duration(seconds: 10);

  final _entries = <_UndoItem>[];
  final _changesController = StreamController<void>.broadcast();

  /// 队列任何变化广播（供 SnackBar 刷新）。
  Stream<void> get changes => _changesController.stream;

  /// 栈顶有效项（无则 null）。
  UndoEntry? get latest => _entries.isEmpty ? null : _entries.last.entry;

  /// 入栈顶，10 秒过期自动丢弃并广播。
  ///
  /// [onExpire] 可选（B46）：条目**到期、被 [clear] 丢弃、或 undo 抛错**时，
  /// 用它清理随条目附带的资源（例如已归档批量删除写入 DB 的撤销备份）。
  /// 成功 undo 的资源由 undo 闭包自己清，这里不会重复调用。
  /// 不传该参数的既有调用方行为完全不变。
  void register(
      {required String label,
      required Future<void> Function() undo,
      Future<void> Function()? onExpire}) {
    final item = _UndoItem(
      entry: UndoEntry(
          id: const Uuid().v4(), label: label, enqueuedAt: DateTime.now()),
      undo: undo,
      onExpire: onExpire,
    );
    item.timer = Timer(_ttl, () {
      _entries.remove(item);
      unawaited(_runOnExpire(item));
      _changesController.add(null);
    });
    _entries.add(item);
    _changesController.add(null);
  }

  /// 弹栈顶、取消其 Timer、执行逆操作闭包、广播；空队列 no-op。
  Future<void> undoLatest() async {
    if (_entries.isEmpty) return;
    final item = _entries.removeLast();
    item.timer?.cancel();
    try {
      await item.undo();
    } catch (_) {
      // undo 失败：连带清理该条目附带的资源（B46 的 DB 备份），再原样抛出。
      await _runOnExpire(item);
      rethrow;
    } finally {
      _changesController.add(null);
    }
  }

  /// 执行条目附带的到期清理；失败只吞掉（备份清理失败不该打断撤销语义，
  /// 下次开库 / 新建备份前还会再清一次）。
  Future<void> _runOnExpire(_UndoItem item) async {
    try {
      await item.onExpire?.call();
    } catch (_) {
      // 故意忽略
    }
  }

  void clear() {
    for (final item in _entries) {
      item.timer?.cancel();
      unawaited(_runOnExpire(item));
    }
    if (_entries.isNotEmpty) {
      _entries.clear();
      _changesController.add(null);
    }
  }
}

class _UndoItem {
  final UndoEntry entry;
  final Future<void> Function() undo;

  /// 可选：条目到期/被清空/undo 失败时的资源清理（B46 用）。
  final Future<void> Function()? onExpire;
  Timer? timer;

  _UndoItem({required this.entry, required this.undo, this.onExpire});
}
