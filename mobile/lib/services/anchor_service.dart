import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'assistant/models.dart';
import 'database.dart';

/// 锚点插入结果：定位失败时 [error] 非空（无写入）；
/// anchorText 多处出现时取第一处并置 [multipleMatches]（details §1.5）。
class AnchorInsertResult {
  final TaskAnchor? anchor;
  final String? error;
  final bool multipleMatches;

  const AnchorInsertResult({this.anchor, this.error})
      : multipleMatches = false;

  const AnchorInsertResult._({this.anchor, this.error, this.multipleMatches = false});

  bool get ok => anchor != null && error == null;
}

/// 从正文移除一个 marker：连同追加式 marker 前面的一个分隔空格一起删，
/// 使「插入 → 移除」往返后正文（与 content_hash）回到插入前状态。
String removeAnchorMarker(String body, String marker) {
  final idx = body.indexOf(marker);
  if (idx < 0) return body;
  var start = idx;
  if (start > 0 && body[start - 1] == ' ') start--;
  return body.substring(0, start) + body.substring(idx + marker.length);
}

/// 残迹化的事务内实现（details §1.5）：把该任务所有 marker 替换为
/// `[任务:<label>]` 纯文本（label 缺省取任务标题），再删除锚点行。
/// 由 [AppDatabase.deleteTasks] 在删除事务内调用；不删任务行本身。
Future<void> residualizeAnchorsForTaskInto(
    DatabaseExecutor db, String taskId) async {
  final anchors = await db
      .query('task_anchors', where: 'task_id = ?', whereArgs: [taskId]);
  if (anchors.isEmpty) return;
  String? taskTitle;
  final taskRows = await db.query('tasks',
      columns: ['title'], where: 'id = ?', whereArgs: [taskId], limit: 1);
  if (taskRows.isNotEmpty) taskTitle = taskRows.first['title'] as String;

  // 按目标分组，一次性改正文
  final byTarget = <String, List<Map<String, Object?>>>{};
  for (final a in anchors) {
    final type = a['target_type'] as String;
    if (type == AnchorTargetType.file) continue; // 文件锚点不入正文
    byTarget.putIfAbsent('$type|${a['target_id']}', () => []).add(a);
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final entry in byTarget.entries) {
    final splitAt = entry.key.indexOf('|');
    final type = entry.key.substring(0, splitAt);
    final targetId = entry.key.substring(splitAt + 1);
    if (type == AnchorTargetType.message) {
      final rows = await db.query('messages',
          where: 'id = ?', whereArgs: [targetId], limit: 1);
      if (rows.isEmpty) continue;
      final r = rows.first;
      var body = r['body'] as String;
      for (final a in entry.value) {
        final label = a['label'] as String? ?? taskTitle ?? '';
        body = body.replaceAll(
            anchorMarker(a['id'] as String), '[任务:$label]');
      }
      await db.update(
        'messages',
        {
          'body': body,
          'edited_at': now,
          'content_hash': computeContentHash(r['package_name'] as String,
              r['title'] as String, body, (r['posted_at'] as num).toInt()),
        },
        where: 'id = ?',
        whereArgs: [targetId],
      );
    } else if (type == AnchorTargetType.note) {
      final rows = await db.query('notes',
          where: 'id = ?', whereArgs: [targetId], limit: 1);
      if (rows.isEmpty) continue;
      var content = rows.first['content'] as String;
      for (final a in entry.value) {
        final label = a['label'] as String? ?? taskTitle ?? '';
        content = content.replaceAll(
            anchorMarker(a['id'] as String), '[任务:$label]');
      }
      await db.update('notes', {'content': content, 'updated_at': now},
          where: 'id = ?', whereArgs: [targetId]);
    }
  }
  await db
      .delete('task_anchors', where: 'task_id = ?', whereArgs: [taskId]);
}

/// 重建某条消息的全部锚点（事务内实现）：清掉旧锚点行与正文 marker，
/// 再按 [taskIds] 顺序在正文末尾以空格分隔追加新 marker 并建行。
/// 悬挂任务 id（已不存在）跳过。供 replaceMessageAnchors 与撤销路径用。
Future<void> replaceMessageAnchorsInto(
    DatabaseExecutor db, String messageId, List<String> taskIds,
    {String createdBy = AnchorCreatedBy.user}) async {
  final rows = await db.query('messages',
      where: 'id = ?', whereArgs: [messageId], limit: 1);
  if (rows.isEmpty) return;
  final r = rows.first;
  var body = r['body'] as String;

  final oldAnchors = await db.query('task_anchors',
      where: "target_type = 'message' AND target_id = ?",
      whereArgs: [messageId]);
  for (final a in oldAnchors) {
    body = removeAnchorMarker(body, anchorMarker(a['id'] as String));
  }
  await db.delete('task_anchors',
      where: "target_type = 'message' AND target_id = ?",
      whereArgs: [messageId]);

  const uuid = Uuid();
  final now = DateTime.now().millisecondsSinceEpoch;
  final markers = <String>[];
  final seen = <String>{};
  for (final taskId in taskIds) {
    if (!seen.add(taskId)) continue;
    final taskRows = await db.query('tasks',
        columns: ['title'], where: 'id = ?', whereArgs: [taskId], limit: 1);
    if (taskRows.isEmpty) continue; // 悬挂引用跳过
    final anchorId = uuid.v4();
    await db.insert('task_anchors', {
      'id': anchorId,
      'task_id': taskId,
      'target_type': AnchorTargetType.message,
      'target_id': messageId,
      'label': taskRows.first['title'] as String,
      'created_by': createdBy,
      'created_at': now,
    });
    markers.add(anchorMarker(anchorId));
  }
  if (markers.isNotEmpty) {
    final tail = markers.join(' ');
    body = body.isEmpty ? tail : '$body $tail';
  }
  await db.update(
    'messages',
    {
      'body': body,
      'edited_at': now,
      'content_hash': computeContentHash(r['package_name'] as String,
          r['title'] as String, body, (r['posted_at'] as num).toInt()),
    },
    where: 'id = ?',
    whereArgs: [messageId],
  );
}

/// 锚点服务（design-v3 §1.1、details §1.5）：任务锚点是正文中的行内对象，
/// 本服务是消息/笔记正文「仅插入/移除锚点 marker」受限写入的执行方
/// （另一写入方是用户自由编辑入口）。两类写入都打 edited_at 留痕，
/// 并按 §1.4 重算 content_hash（strip 内建于 computeContentHash）。
class AnchorService {
  AnchorService._();

  static final AnchorService instance = AnchorService._();

  static const _uuid = Uuid();

  /// 渲染预取缓存（details §1.2）：anchorId → 锚点行。
  final Map<String, TaskAnchor> _cache = {};

  /// 插入锚点：在 [anchorText] 首次出现处之后插入 `⟦task:<id>⟧` marker
  /// 并写 task_anchors 行；anchorText 为空时追加到正文末尾（空格分隔）。
  /// 多处出现取第一处并在结果里注明；定位失败返回 error、不落任何写入。
  /// 文件锚点不动内容，只落表行（§1.1：整个文件关联此任务）。
  Future<AnchorInsertResult> insertAnchor({
    required String taskId,
    required String targetType,
    required String targetId,
    String? anchorText,
    String? label,
    String createdBy = AnchorCreatedBy.user,
  }) async {
    final db = AppDatabase.instance;
    final effectiveLabel =
        label ?? (await db.getTaskById(taskId))?.title;
    final anchor = TaskAnchor(
      id: _uuid.v4(),
      taskId: taskId,
      targetType: targetType,
      targetId: targetId,
      label: effectiveLabel,
      createdBy: createdBy,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final marker = anchorMarker(anchor.id);

    if (targetType == AnchorTargetType.file) {
      await db.insertAnchor(anchor);
      _cache[anchor.id] = anchor;
      return AnchorInsertResult(anchor: anchor);
    }

    var multiple = false;
    if (targetType == AnchorTargetType.message) {
      final msg = await db.getMessageById(targetId);
      if (msg == null) {
        return AnchorInsertResult._(error: '目标消息不存在: $targetId');
      }
      final body = msg.body;
      final at = anchorText;
      String nextBody;
      if (at == null || at.isEmpty) {
        nextBody = body.isEmpty ? marker : '$body $marker';
      } else {
        final first = body.indexOf(at);
        if (first < 0) {
          return AnchorInsertResult._(error: '定位失败：正文中不存在「$at」');
        }
        multiple = body.indexOf(at, first + at.length) >= 0;
        final insertAt = first + at.length;
        nextBody = body.substring(0, insertAt) + marker + body.substring(insertAt);
      }
      // 受限写入：edited_at 留痕 + content_hash 重算（updateMessageBody 内）
      await db.updateMessageBody(targetId, nextBody);
    } else if (targetType == AnchorTargetType.note) {
      final note = await db.getNoteById(targetId);
      if (note == null) {
        return AnchorInsertResult._(error: '目标笔记不存在: $targetId');
      }
      final content = note.content;
      final at = anchorText;
      String nextContent;
      if (at == null || at.isEmpty) {
        nextContent = content.isEmpty ? marker : '$content $marker';
      } else {
        final first = content.indexOf(at);
        if (first < 0) {
          return AnchorInsertResult._(error: '定位失败：正文中不存在「$at」');
        }
        multiple = content.indexOf(at, first + at.length) >= 0;
        final insertAt = first + at.length;
        nextContent =
            content.substring(0, insertAt) + marker + content.substring(insertAt);
      }
      await db.updateNote(note.copyWith(content: nextContent));
    } else {
      return AnchorInsertResult._(error: '未知锚点目标类型: $targetType');
    }

    await db.insertAnchor(anchor);
    _cache[anchor.id] = anchor;
    return AnchorInsertResult._(anchor: anchor, multipleMatches: multiple);
  }

  /// 移除锚点：正文中 marker 一并清除（连追加式分隔空格），锚点行删除。
  /// edited_at 留痕 + content_hash 重算。锚点不存在返回 false。
  Future<bool> removeAnchor(String anchorId) async {
    final db = AppDatabase.instance;
    final anchor = await db.getAnchorById(anchorId);
    if (anchor == null) return false;
    final marker = anchorMarker(anchor.id);
    if (anchor.targetType == AnchorTargetType.message) {
      final msg = await db.getMessageById(anchor.targetId);
      if (msg != null) {
        final nextBody = removeAnchorMarker(msg.body, marker);
        if (nextBody != msg.body) {
          await db.updateMessageBody(anchor.targetId, nextBody);
        }
      }
    } else if (anchor.targetType == AnchorTargetType.note) {
      final note = await db.getNoteById(anchor.targetId);
      if (note != null) {
        final nextContent = removeAnchorMarker(note.content, marker);
        if (nextContent != note.content) {
          await db.updateNote(note.copyWith(content: nextContent));
        }
      }
    }
    // file：不入正文，只删行
    await db.deleteAnchor(anchorId);
    _cache.remove(anchorId);
    return true;
  }

  /// 删除任务时的残迹化（details §1.5）：该任务所有 marker 替换为
  /// label 纯文本（`[任务:买菜]`），锚点行删除。一般在删除事务内由
  /// [AppDatabase.deleteTasks] 调 [residualizeAnchorsForTaskInto]；
  /// 独立调用时这里自包事务。
  Future<void> residualizeForTask(String taskId) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) => residualizeAnchorsForTaskInto(txn, taskId));
    _cache.clear();
  }

  /// 重建某条消息的全部锚点（AI 确认/撤销用）：清旧建新，
  /// marker 追加在正文末尾。单事务。
  Future<void> replaceMessageAnchors(String messageId, List<String> taskIds,
      {String createdBy = AnchorCreatedBy.user}) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) => replaceMessageAnchorsInto(txn, messageId,
        taskIds,
        createdBy: createdBy));
    _cache.clear();
  }

  /// 渲染预取（details §1.2）：从一批正文中提取 marker id，缓存未命中的
  /// 批量联查一次入库，返回「本次提取到的 id → 锚点」映射（缺失行不返回）。
  Future<Map<String, TaskAnchor>> prefetchForBodies(
      Iterable<String> bodies) async {
    final ids = <String>{};
    for (final body in bodies) {
      for (final m in anchorMarkerPattern.allMatches(body)) {
        ids.add(m.group(1)!.toLowerCase());
      }
    }
    if (ids.isEmpty) return const {};
    final missing =
        ids.where((id) => !_cache.containsKey(id)).toList(growable: false);
    if (missing.isNotEmpty) {
      for (final a in await AppDatabase.instance.anchorsByIds(missing)) {
        _cache[a.id] = a;
      }
    }
    return {
      for (final id in ids)
        if (_cache.containsKey(id)) id: _cache[id]!,
    };
  }

  /// 清空预取缓存（锚点批量变更后调用方不必精确失效时的兜底）。
  void clearCache() => _cache.clear();
}
