import 'package:uuid/uuid.dart';

import '../../models/conversation.dart';
import '../../models/note.dart';
import '../../models/task.dart';
import '../anchor_service.dart';
import '../crdt.dart';
import '../database.dart';
import '../undo_service.dart';
import 'models.dart';
import 'proposal_service.dart';
import 'tool_spec.dart';

/// 一次提案执行的结果。
class ProposalExecution {
  final bool ok;

  /// 人类可读结果（回注对话为 tool 消息，也用于待确认区展示）。
  final String message;

  const ProposalExecution(this.ok, this.message);
}

/// 提案执行器（design-v3 §5.4、details §2.3 + crdt.md §3.2）：
/// 审批通过 → 存在性校验 + 权限边界 → **三态裁决**（base 比对）→ 执行 →
/// 状态置 applied/failed/superseded → 结果回注原对话（role='tool'）→ 入撤销队列。
///
/// 三态裁决（v12）：
/// - 目标当前版本 == 提案 base → 直接落 op（无并发）；
/// - 版本漂移但冲突方是助理（另一对话）→ LWW 后落者赢，自动 rebase 生效；
/// - 版本漂移且冲突方是人/系统 → 提案置 superseded（人优先，永不自动覆盖），
///   卡片提供「以当前状态重新提交」入口（[resubmit]，base 刷新后可再审批）。
/// 「失败」的判定从「base 过期」收窄为「目标不存在/权限拒绝」（crdt.md §3.3）。
///
/// 权限边界在这里强制（与 proposal_service 的校验分离，双保险）：
/// 已归档任务拒绝 update/delete；首版无笔记/文件删除工具；设置/密钥不可达。
///
/// 撤销：执行前把逆操作所需快照写进 payload 的 `_undo` 键（随提案落库，
/// 历史区撤销入口可事后反悔）；同时入 UndoService 10 秒快捷撤销队列。
/// 撤销 = 投递逆 op（逆操作同样进 op_log，crdt.md §5），提案退回 pending。
class ProposalExecutor {
  ProposalExecutor._();

  static final ProposalExecutor instance = ProposalExecutor._();

  static const _uuid = Uuid();

  static const _undoKey = '_undo';

  // ---- 审批执行 ----

  /// 审批并执行一条 pending 提案。
  Future<ProposalExecution> approve(String proposalId) async {
    final db = AppDatabase.instance;
    final proposal = await db.getProposalById(proposalId);
    if (proposal == null) {
      return ProposalExecution(false, '提案不存在: $proposalId');
    }
    if (proposal.status != ProposalStatus.pending) {
      return ProposalExecution(false, '提案状态不可审批: ${proposal.status}');
    }
    await db.transitionProposal(proposalId, ProposalStatus.approved);

    // 存在性校验（目标不存在 → failed，crdt.md §3.3 收窄后的失败定义）
    final validationError =
        await ProposalService.instance.validate(proposal.tool, proposal.payload);
    if (validationError != null) {
      await db.transitionProposal(proposalId, ProposalStatus.failed);
      final exec = ProposalExecution(false, '执行前校验失败：$validationError');
      await _reportBack(proposal, exec);
      return exec;
    }
    final permissionError =
        await _checkPermission(proposal.tool, proposal.payload);
    if (permissionError != null) {
      await db.transitionProposal(proposalId, ProposalStatus.failed);
      final exec = ProposalExecution(false, permissionError);
      await _reportBack(proposal, exec);
      return exec;
    }

    // 三态裁决（crdt.md §3.2）：base 漂移且冲突方是人/系统 → superseded
    final supersededReason = await _adjudicate(proposal);
    if (supersededReason != null) {
      await db.transitionProposal(proposalId, ProposalStatus.superseded);
      final exec = ProposalExecution(false, supersededReason);
      await _reportBack(proposal, exec);
      return exec;
    }

    final actor = OpActor.assistant(proposal.conversationId ?? 'unknown');
    ProposalExecution exec;
    Map<String, dynamic>? undo;
    try {
      (exec, undo) = await _execute(proposal.tool, proposal.payload, actor);
    } catch (e) {
      exec = ProposalExecution(false, '执行异常：$e');
    }

    if (exec.ok) {
      if (undo != null) {
        // 逆操作快照随提案落库（历史区撤销入口的数据来源）
        await db.insertProposal(_withUndo(
            await db.getProposalById(proposalId) ?? proposal, undo));
      }
      await db.transitionProposal(proposalId, ProposalStatus.applied);
      UndoService.instance.register(
        label: '撤销：${proposal.summary}',
        undo: () => undoApplied(proposalId),
      );
    } else {
      await db.transitionProposal(proposalId, ProposalStatus.failed);
    }
    await _reportBack(proposal, exec);
    return exec;
  }

  /// 三态裁决（crdt.md §3.2）：返回非 null = 置 superseded 的原因。
  ///
  /// 逐字段比对 base：字段当前版本与 base 相同 → 不相交，放行；
  /// 不同 → 看冲突方 actor：人/系统 → superseded（人优先）；
  /// 助理 → 放行（LWW 后落者赢，新 op 的 lamport 更大）。
  /// 无 base 的老提案直接放行（向后兼容）。
  Future<String?> _adjudicate(ChangeProposal proposal) async {
    final base = proposal.payload['base'];
    if (base is! Map) return null;
    final db = AppDatabase.instance;

    Future<String?> checkField(String target, dynamic baseJson) async {
      final cur = await db.currentVersion(target);
      final baseStamp =
          baseJson == null ? null : OpStamp.fromJson((baseJson as Map).cast<String, dynamic>());
      if (cur == baseStamp) return null;
      if (cur != null && !OpActor.isAssistant(cur.actor)) {
        return '已被你的修改覆盖（$target）';
      }
      return null;
    }

    switch (proposal.tool) {
      case ToolNames.taskUpdate:
        final fields = base['fields'];
        if (fields is! Map) return null;
        final id = proposal.payload['id'] as String;
        for (final e in fields.entries) {
          final reason =
              await checkField(taskFieldTarget(id, e.key as String), e.value);
          if (reason != null) {
            return '任务字段「${e.key}」$reason，可「以当前状态重新提交」';
          }
        }
        return null;
      case ToolNames.taskDelete:
        final id = proposal.payload['id'] as String;
        final cur = await db.currentVersionPrefix(taskPrefix(id));
        final baseJson = base['task'];
        final baseStamp = baseJson == null
            ? null
            : OpStamp.fromJson((baseJson as Map).cast<String, dynamic>());
        if (cur == baseStamp) return null;
        if (cur != null && !OpActor.isAssistant(cur.actor)) {
          return '该任务在你审批期间被修改，删除提案已被覆盖（人优先）';
        }
        return null;
      case ToolNames.messageSetPriority:
        final fields = base['fields'];
        if (fields is! Map) return null;
        final id = proposal.payload['messageId'] as String;
        final reason = await checkField(
            messageFieldTarget(id, 'priority'), fields['priority']);
        if (reason != null) return '消息优先级$reason，可「以当前状态重新提交」';
        return null;
      default:
        return null;
    }
  }

  /// superseded 提案「以当前状态重新提交」（crdt.md §3.2）：base 刷新为
  /// 目标当前版本后退回 pending，可再次审批。非 superseded 返回 false。
  Future<bool> resubmit(String proposalId) async {
    final db = AppDatabase.instance;
    final proposal = await db.getProposalById(proposalId);
    if (proposal == null || proposal.status != ProposalStatus.superseded) {
      return false;
    }
    final newBase = await ProposalService.captureBase(
        proposal.tool, proposal.payload);
    final payload = {...proposal.payload}..remove('base');
    if (newBase != null) payload['base'] = newBase;
    await db.insertProposal(ChangeProposal(
      id: proposal.id,
      conversationId: proposal.conversationId,
      batchId: proposal.batchId,
      tool: proposal.tool,
      summary: proposal.summary,
      payload: payload,
      status: ProposalStatus.pending,
      createdAt: proposal.createdAt,
    ));
    return true;
  }

  /// 拒绝一条 pending 提案。
  Future<bool> reject(String proposalId) =>
      AppDatabase.instance.transitionProposal(proposalId, ProposalStatus.rejected);

  /// 撤销一条已应用（applied）的提案：按 `_undo` 快照投递逆 op
  /// （逆操作进 op_log，actor=user——撤销动作由人触发，crdt.md §5），
  /// 提案退回 pending。非 applied 或无快照时返回 false。
  Future<bool> undoApplied(String proposalId) async {
    final db = AppDatabase.instance;
    final proposal = await db.getProposalById(proposalId);
    if (proposal == null || proposal.status != ProposalStatus.applied) {
      return false;
    }
    final undo = proposal.payload[_undoKey];
    if (undo is! Map) return false;
    try {
      await _applyUndo(
          proposal.tool, undo.cast<String, dynamic>(), proposal.payload);
    } catch (_) {
      return false;
    }
    return db.transitionProposal(proposalId, ProposalStatus.pending);
  }

  /// 权限边界（details §2.3，与校验分离双保险）：已归档任务拒绝 update/delete。
  Future<String?> _checkPermission(String tool, Map<String, dynamic> args) async {
    if (tool == ToolNames.taskUpdate || tool == ToolNames.taskDelete) {
      final task = await AppDatabase.instance.getTaskById(args['id'] as String);
      if (task != null && task.status == TaskStatus.archived) {
        return '权限边界：已归档任务不可${tool == ToolNames.taskUpdate ? '修改' : '删除'}';
      }
    }
    return null;
  }

  // ---- 写工具执行 ----

  static int? _parseLocalMs(dynamic v) {
    if (v is! String || v.trim().isEmpty) return null;
    return DateTime.tryParse(v.trim().replaceFirst(' ', 'T'))
        ?.millisecondsSinceEpoch;
  }

  /// 执行写工具；返回 (结果, 逆操作快照)。快照为 null 表示该工具不可撤销
  /// （当前全部写工具都可撤销）。[actor] = `assistant:<conversationId>`，
  /// 所有物化写入经 op-recording 路径落 op_log。
  Future<(ProposalExecution, Map<String, dynamic>?)> _execute(
      String tool, Map<String, dynamic> args, String actor) async {
    final db = AppDatabase.instance;
    switch (tool) {
      case ToolNames.taskCreate:
        final now = DateTime.now().millisecondsSinceEpoch;
        final task = Task(
          id: _uuid.v4(),
          title: (args['title'] as String).trim(),
          description: (args['description'] as String?)?.trim(),
          kind: args['kind'] == TaskKind.range ? TaskKind.range : TaskKind.point,
          startAt: _parseLocalMs(args['startAt']),
          endAt: _parseLocalMs(args['endAt']),
          priority: args['priority'] as String? ?? TaskPriority.normal,
          parentId: args['parentId'] as String?,
          status: TaskStatus.active,
          createdAt: now,
          updatedAt: now,
        );
        await db.insertTask(task);
        return (
          ProposalExecution(true, '已创建任务「${task.title}」（${task.id}）'),
          {'op': 'task.delete', 'taskId': task.id},
        );

      case ToolNames.taskUpdate:
        final old = (await db.getTaskById(args['id'] as String))!;
        var next = old;
        if (args.containsKey('title')) {
          next = next.copyWith(title: (args['title'] as String).trim());
        }
        if (args.containsKey('description')) {
          next =
              next.copyWith(description: () => args['description'] as String?);
        }
        if (args.containsKey('kind')) {
          next = next.copyWith(kind: args['kind'] as String);
        }
        if (args.containsKey('startAt')) {
          next = next.copyWith(startAt: () => _parseLocalMs(args['startAt']));
        }
        if (args.containsKey('endAt')) {
          next = next.copyWith(endAt: () => _parseLocalMs(args['endAt']));
        }
        if (args.containsKey('priority')) {
          next = next.copyWith(priority: args['priority'] as String);
        }
        if (args.containsKey('status')) {
          next = next.copyWith(status: args['status'] as String);
        }
        await db.updateTask(next, actor: actor);
        return (
          ProposalExecution(true, '已修改任务「${next.title}」'),
          {'op': 'task.restore', 'task': old.toRow()},
        );

      case ToolNames.taskDelete:
        final old = (await db.getTaskById(args['id'] as String))!;
        // 删除前快照锚点行（v12 起锚点不入正文，撤销 = 任务行 + 锚点行回插）。
        final snapshot = await db.snapshotTaskDeletion([old.id]);
        await db.deleteTasks([old.id], actor: actor);
        return (
          ProposalExecution(
              true,
              '已删除任务「${old.title}」'
              '${snapshot.anchors.isEmpty ? '' : '（${snapshot.anchors.length} 个锚点一并删除，撤销将恢复）'}'),
          {
            'op': 'task.restore',
            'task': old.toRow(),
            'snapshot': snapshot.toJson(),
          },
        );

      case ToolNames.noteCreate:
        final chapterId =
            args['chapterId'] as String? ?? await _defaultChapterId(db);
        final now = DateTime.now().millisecondsSinceEpoch;
        final note = Note(
          id: _uuid.v4(),
          chapterId: chapterId,
          title: (args['title'] as String).trim(),
          content: args['content'] as String? ?? '',
          contentFormat: 'markdown',
          createdAt: now,
          updatedAt: now,
        );
        await db.insertNote(note);
        return (
          ProposalExecution(true, '已创建笔记「${note.title}」（${note.id}）'),
          {'op': 'note.delete', 'noteId': note.id},
        );

      case ToolNames.noteAppend:
        final note = (await db.getNoteById(args['noteId'] as String))!;
        final addition = args['content'] as String;
        final joined = note.content.isEmpty
            ? addition
            : note.content.endsWith('\n')
                ? '${note.content}$addition'
                : '${note.content}\n$addition';
        // 追加集语义（crdt.md §4.4）：在审批时刻的最新正文上追加，
        // 人与助理的并发追加互不丢失（天然 rebase）。
        await db.updateNote(note.copyWith(content: joined),
            actor: actor,
            opKind: OpKind.append,
            opPayload: {'segment': addition});
        return (
          ProposalExecution(true, '已向笔记「${note.title}」追加内容'),
          {'op': 'note.content', 'noteId': note.id, 'content': note.content},
        );

      case ToolNames.anchorCreate:
        final result = await AnchorService.instance.insertAnchor(
          taskId: args['taskId'] as String,
          targetType: args['targetType'] as String,
          targetId: args['targetId'] as String,
          createdBy: AnchorCreatedBy.ai,
          actor: actor,
        );
        if (!result.ok) {
          return (ProposalExecution(false, result.error ?? '锚点创建失败'), null);
        }
        return (
          ProposalExecution(
              true,
              '已创建锚点（${result.anchor!.id}）'
              '${result.alreadyExists ? '；相同关联已存在，幂等复用' : ''}'),
          {'op': 'anchor.remove', 'anchorId': result.anchor!.id},
        );

      case ToolNames.anchorRemove:
        final anchor = (await db.getAnchorById(args['anchorId'] as String))!;
        // 快照锚点行：撤销时原样回插（v12 起锚点不入正文，无正文可恢复）。
        final removed =
            await AnchorService.instance.removeAnchor(anchor.id, actor: actor);
        if (!removed) {
          return (const ProposalExecution(false, '锚点不存在'), null);
        }
        return (
          ProposalExecution(true, '已移除锚点 ${anchor.id}'),
          {
            'op': 'anchor.restore',
            'anchor': {
              'id': anchor.id,
              'task_id': anchor.taskId,
              'target_type': anchor.targetType,
              'target_id': anchor.targetId,
              'label': anchor.label,
              'created_by': anchor.createdBy,
              'created_at': anchor.createdAt,
            },
          },
        );

      case ToolNames.messageSetPriority:
        final msg = (await db.getMessageById(args['messageId'] as String))!;
        await db.updateMessagePriority([msg.id], args['priority'] as String,
            actor: actor);
        return (
          ProposalExecution(
              true, '已把消息「${msg.title}」标为 ${args['priority']}'),
          {'op': 'message.priority', 'messageId': msg.id, 'priority': msg.priority},
        );

      default:
        return (ProposalExecution(false, '无可执行的工具: $tool'), null);
    }
  }

  // ---- 撤销（逆 op，crdt.md §5：撤销动作由人触发，一律以 user 落账） ----

  Future<void> _applyUndo(String tool, Map<String, dynamic> undo,
      Map<String, dynamic> payload) async {
    final db = AppDatabase.instance;
    const actor = OpActor.user;
    switch (undo['op']) {
      case 'task.delete':
        await db.deleteTasks([undo['taskId'] as String], actor: actor);
      case 'task.restore':
        await db
            .insertTask(Task.fromRow((undo['task'] as Map).cast<String, Object?>()));
        // v12 起快照只含锚点行（正文不再受任务删除影响）；
        // 旧快照的 bodies 由 restore 内部剥离 marker 后兼容回写。
        final snapshot = undo['snapshot'];
        if (snapshot is Map) {
          await db.restoreTaskDeletionSnapshot(
              TaskDeletionSnapshot.fromJson(snapshot.cast<String, dynamic>()));
        }
        // 恢复 = 墓碑的逆 op：同 target 落 lww_set，撤销本身进 op_log。
        await db.recordOp(
            actor: actor,
            target: taskPrefix((undo['task'] as Map)['id'] as String),
            kind: OpKind.lwwSet,
            payload: {'restored': true});
      case 'note.delete':
        await db.deleteNote(undo['noteId'] as String);
      case 'note.content':
        final note = await db.getNoteById(undo['noteId'] as String);
        if (note != null) {
          await db.updateNote(note.copyWith(content: undo['content'] as String),
              actor: actor);
        }
      case 'anchor.remove':
        await AnchorService.instance
            .removeAnchor(undo['anchorId'] as String, actor: actor);
      case 'anchor.restore':
        final a = (undo['anchor'] as Map).cast<String, dynamic>();
        // 旧版撤销 payload 可能带 'body'（行内 marker 时代的正文快照）：
        // 剥离 marker 后回写，避免把 ⟦task:⟧ 重新带入正文。
        final targetType = a['target_type'] as String;
        final targetId = a['target_id'] as String;
        final body = undo['body'] as String?;
        if (body != null) {
          final stripped = stripAnchorMarkers(body);
          if (targetType == AnchorTargetType.message) {
            await db.updateMessageBody(targetId, stripped, actor: actor);
          } else if (targetType == AnchorTargetType.note) {
            final note = await db.getNoteById(targetId);
            if (note != null) {
              await db.updateNote(note.copyWith(content: stripped),
                  actor: actor);
            }
          }
        }
        await db.insertAnchor(
            TaskAnchor(
              id: a['id'] as String,
              taskId: a['task_id'] as String,
              targetType: targetType,
              targetId: targetId,
              label: a['label'] as String?,
              createdBy: a['created_by'] as String,
              createdAt: (a['created_at'] as num).toInt(),
            ),
            actor: actor);
      case 'message.priority':
        await db.updateMessagePriority(
            [undo['messageId'] as String], undo['priority'] as String,
            actor: actor);
      default:
        throw StateError('未知逆操作: ${undo['op']}');
    }
  }

  // ---- 只读工具（无需审批，直接执行，结果回注对话） ----

  Future<String> executeReadTool(String tool, Map<String, dynamic> args) async {
    final db = AppDatabase.instance;
    switch (tool) {
      case ToolNames.taskList:
        final status = args['status'] as String? ?? TaskStatus.active;
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final tasks = await db.getTasks(status: status, limit: limit);
        if (tasks.isEmpty) return '没有 $status 任务';
        return tasks
            .map((t) =>
                '${t.id} | ${t.title} | ${_fmtMs(t.startAt)} | ${t.priority}')
            .join('\n');

      case ToolNames.taskSearch:
        final q = (args['query'] as String).toLowerCase();
        final all = await db.getTasks();
        final hits = all
            .where((t) =>
                t.title.toLowerCase().contains(q) ||
                (t.description ?? '').toLowerCase().contains(q))
            .take(20)
            .toList();
        if (hits.isEmpty) return '没有匹配「${args['query']}」的任务';
        return hits
            .map((t) =>
                '${t.id} | ${t.title} | ${t.status} | ${_fmtMs(t.startAt)}')
            .join('\n');

      case ToolNames.noteRead:
        final note = await db.getNoteById(args['noteId'] as String);
        if (note == null) return '笔记不存在: ${args['noteId']}';
        final content = note.content.length > 4000
            ? '${note.content.substring(0, 4000)}…（已截断）'
            : note.content;
        return '《${note.title}》(${note.id})\n$content';

      case ToolNames.librarySearch:
        final q = (args['query'] as String).toLowerCase();
        final types = ((args['types'] as List?) ?? const [
              ChatAttachmentType.note,
              ChatAttachmentType.message,
              ChatAttachmentType.file
            ])
            .map((e) => e.toString())
            .toSet();
        final hits = <String>[];
        if (types.contains(ChatAttachmentType.note)) {
          for (final nb in await db.getNotebooks()) {
            for (final ch in await db.getChapters(nb.id)) {
              for (final n in await db.getNotes(ch.id)) {
                if (n.title.toLowerCase().contains(q) ||
                    n.content.toLowerCase().contains(q)) {
                  hits.add('[#note:${n.title}] (${n.id})');
                }
              }
            }
          }
        }
        if (types.contains(ChatAttachmentType.message)) {
          for (final m in await db.getMessages()) {
            if (m.title.toLowerCase().contains(q) ||
                m.body.toLowerCase().contains(q)) {
              hits.add('[#message:${m.title}] (${m.id})');
            }
          }
        }
        if (types.contains(ChatAttachmentType.file)) {
          for (final f in await db.getFiles()) {
            if (f.name.toLowerCase().contains(q)) {
              hits.add('[#file:${f.name}] (${f.id})');
            }
          }
        }
        if (hits.isEmpty) return '库中没有匹配「${args['query']}」的内容';
        return hits.take(20).join('\n');

      default:
        return '未知只读工具: $tool';
    }
  }

  static String _fmtMs(int? ms) => ms == null
      ? '无时间'
      : DateTime.fromMillisecondsSinceEpoch(ms).toString().substring(0, 16);

  /// note.create 缺省章节：第一个笔记本的第一个章节；库为空时建「AI 笔记」。
  Future<String> _defaultChapterId(AppDatabase db) async {
    for (final nb in await db.getNotebooks()) {
      final chapters = await db.getChapters(nb.id);
      if (chapters.isNotEmpty) return chapters.first.id;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final nb = Notebook(
        id: _uuid.v4(), name: 'AI 笔记', sort: 0, createdAt: now);
    await db.insertNotebook(nb);
    final ch = Chapter(
        id: _uuid.v4(),
        notebookId: nb.id,
        name: '默认',
        sort: 0,
        createdAt: now);
    await db.insertChapter(ch);
    return ch.id;
  }

  // ---- 回注与快照 ----

  ChangeProposal _withUndo(ChangeProposal p, Map<String, dynamic> undo) =>
      ChangeProposal(
        id: p.id,
        conversationId: p.conversationId,
        batchId: p.batchId,
        tool: p.tool,
        summary: p.summary,
        payload: {...p.payload, _undoKey: undo},
        status: p.status,
        createdAt: p.createdAt,
        resolvedAt: p.resolvedAt,
      );

  /// 执行结果回注原对话（design-v3 §1.4：role='tool' 消息，保持上下文连贯）。
  /// 对话已删除（conversationId 置空）时跳过。
  Future<void> _reportBack(
      ChangeProposal proposal, ProposalExecution exec) async {
    final conversationId = proposal.conversationId;
    if (conversationId == null) return;
    final db = AppDatabase.instance;
    if (await db.getConversationById(conversationId) == null) return;
    await db.insertChatMessage(_toolMessage(
      conversationId,
      '${exec.ok ? '✅' : '❌'} [${proposal.tool}] ${exec.message}',
    ));
    await db.touchConversation(conversationId);
  }

  /// 只读工具结果/校验失败的回注（由 assistant_service 调用）。
  Future<void> reportToolMessage(String conversationId, String content) async {
    final db = AppDatabase.instance;
    if (await db.getConversationById(conversationId) == null) return;
    await db.insertChatMessage(_toolMessage(conversationId, content));
    await db.touchConversation(conversationId);
  }

  ChatMessage _toolMessage(String conversationId, String content) {
    return ChatMessage(
      id: _uuid.v4(),
      conversationId: conversationId,
      role: ChatRole.tool,
      content: content,
      status: ChatMessageStatus.done,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
