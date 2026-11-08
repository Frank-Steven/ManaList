import 'package:uuid/uuid.dart';

import 'assistant/models.dart';
import 'crdt.dart';
import 'database.dart';

/// 锚点插入结果：目标不存在等校验失败时 [error] 非空（无写入）。
class AnchorInsertResult {
  final TaskAnchor? anchor;
  final String? error;

  /// 已存在相同 (taskId, targetType, targetId) 的锚点，幂等返回既有行。
  final bool alreadyExists;

  const AnchorInsertResult({this.anchor, this.error})
      : alreadyExists = false;

  const AnchorInsertResult._({this.anchor, this.error, this.alreadyExists = false});

  bool get ok => anchor != null && error == null;
}

/// 锚点服务（anchors-v2.md §2）：锚点 = 库中基本对象（消息条/笔记章节/文件）
/// ↔ 任务 的关联，只落 task_anchors 表，**永不触碰正文**。
///
/// 并发语义（crdt.md §4.3 OR-Set）：增删经 [AppDatabase.insertAnchor] /
/// [AppDatabase.deleteAnchor] 落 or_add / or_remove op；同一三元组重复
/// 添加在服务层幂等去重（返回既有行）。
class AnchorService {
  AnchorService._();

  static final AnchorService instance = AnchorService._();

  static const _uuid = Uuid();

  /// 创建对象级锚点。目标不存在返回 error；同三元组已存在幂等返回既有行。
  /// [actor] 为 op_log 落账身份：人工路径缺省 user，助理提案执行路径由
  /// proposal_executor 传 `assistant:<conversationId>`。
  Future<AnchorInsertResult> insertAnchor({
    required String taskId,
    required String targetType,
    required String targetId,
    String? label,
    String createdBy = AnchorCreatedBy.user,
    String actor = OpActor.user,
  }) async {
    final db = AppDatabase.instance;
    final exists = switch (targetType) {
      AnchorTargetType.message => await db.getMessageById(targetId) != null,
      AnchorTargetType.chapter => await db.getChapterById(targetId) != null,
      AnchorTargetType.file => await db.getFileById(targetId) != null,
      _ => null,
    };
    if (exists == null) {
      return AnchorInsertResult._(error: '未知锚点目标类型: $targetType');
    }
    if (!exists) {
      return AnchorInsertResult._(error: '锚点目标不存在: $targetType/$targetId');
    }
    if (await db.getTaskById(taskId) == null) {
      return AnchorInsertResult._(error: '任务不存在: $taskId');
    }

    final existing = await db.anchorsForTarget(targetType, targetId);
    for (final a in existing) {
      if (a.taskId == taskId) {
        return AnchorInsertResult._(anchor: a, alreadyExists: true);
      }
    }

    final anchor = TaskAnchor(
      id: _uuid.v4(),
      taskId: taskId,
      targetType: targetType,
      targetId: targetId,
      label: label ?? (await db.getTaskById(taskId))?.title,
      createdBy: createdBy,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insertAnchor(anchor, actor: actor);
    return AnchorInsertResult(anchor: anchor);
  }

  /// 移除锚点（只删表行；OR-Set 移除只覆盖观察到的 tag，
  /// 并发再添加的新 tag 按 add-wins 保留）。锚点不存在返回 false。
  Future<bool> removeAnchor(String anchorId,
      {String actor = OpActor.user}) async {
    final db = AppDatabase.instance;
    if (await db.getAnchorById(anchorId) == null) return false;
    await db.deleteAnchor(anchorId, actor: actor);
    return true;
  }
}
