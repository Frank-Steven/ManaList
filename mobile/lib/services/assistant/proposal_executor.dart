import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../models/conversation.dart';
import '../../models/note.dart';
import '../../models/task.dart';
import '../anchor_service.dart';
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

/// 提案执行器（design-v3 §5.4、details §2.3）：
/// 审批通过 → 二次校验（目标仍存在 + 权限边界）→ 执行 → 状态置 applied/failed
/// → 结果回注原对话（role='tool'）→ 入撤销队列。
///
/// 权限边界在这里强制（与 proposal_service 的校验分离，双保险）：
/// 已归档任务拒绝 update/delete；首版无笔记/文件删除工具；设置/密钥不可达。
///
/// 撤销：执行前把逆操作所需快照写进 payload 的 `_undo` 键（随提案落库，
/// 历史区撤销入口可事后反悔）；同时入 UndoService 10 秒快捷撤销队列。
/// 撤销后提案退回 pending（可重新审批或拒绝）。
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

    // 二次校验（审批时刻目标可能已变化，details §2.3「执行时二次校验存在性」）
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

    ProposalExecution exec;
    Map<String, dynamic>? undo;
    try {
      (exec, undo) = await _execute(proposal.tool, proposal.payload);
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

  /// 拒绝一条 pending 提案。
  Future<bool> reject(String proposalId) =>
      AppDatabase.instance.transitionProposal(proposalId, ProposalStatus.rejected);

  /// 撤销一条已应用（applied）的提案：按 `_undo` 快照执行逆操作，
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
  /// （当前全部写工具都可撤销）。
  Future<(ProposalExecution, Map<String, dynamic>?)> _execute(
      String tool, Map<String, dynamic> args) async {
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
        await db.updateTask(next);
        return (
          ProposalExecution(true, '已修改任务「${next.title}」'),
          {'op': 'task.restore', 'task': old.toRow()},
        );

      case ToolNames.taskDelete:
        final old = (await db.getTaskById(args['id'] as String))!;
        // 删除前快照完整状态：锚点行 + 受影响正文原文（撤销整体复原）。
        final snapshot = await db.snapshotTaskDeletion([old.id]);
        await db.deleteTasks([old.id]);
        return (
          ProposalExecution(
              true,
              '已删除任务「${old.title}」'
              '${snapshot.anchors.isEmpty ? '' : '（${snapshot.anchors.length} 个锚点已残迹化，撤销将一并恢复）'}'),
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
        await db.updateNote(note.copyWith(content: joined));
        return (
          ProposalExecution(true, '已向笔记「${note.title}」追加内容'),
          {'op': 'note.content', 'noteId': note.id, 'content': note.content},
        );

      case ToolNames.noteReplaceSection:
        final note = (await db.getNoteById(args['noteId'] as String))!;
        final heading = (args['heading'] as String).trim();
        final replaced =
            _replaceSection(note.content, heading, args['content'] as String);
        if (replaced == null) {
          return (ProposalExecution(false, '笔记「${note.title}」中找不到标题「$heading」'), null);
        }
        await db.updateNote(note.copyWith(content: replaced));
        return (
          ProposalExecution(true, '已替换笔记「${note.title}」的「$heading」区段'),
          {'op': 'note.content', 'noteId': note.id, 'content': note.content},
        );

      case ToolNames.anchorCreate:
        final result = await AnchorService.instance.insertAnchor(
          taskId: args['taskId'] as String,
          targetType: args['targetType'] as String,
          targetId: args['targetId'] as String,
          anchorText: args['anchorText'] as String?,
          createdBy: AnchorCreatedBy.ai,
        );
        if (!result.ok) {
          return (ProposalExecution(false, result.error ?? '锚点创建失败'), null);
        }
        return (
          ProposalExecution(
              true,
              '已创建锚点（${result.anchor!.id}）'
              '${result.multipleMatches ? '；定位文本多处出现，取第一处' : ''}'),
          {'op': 'anchor.remove', 'anchorId': result.anchor!.id},
        );

      case ToolNames.anchorRemove:
        final anchor = (await db.getAnchorById(args['anchorId'] as String))!;
        // 快照锚点行 + 目标正文：撤销时原样恢复（位置/分隔空格不变）。
        String? bodyBefore;
        if (anchor.targetType == AnchorTargetType.message) {
          bodyBefore = (await db.getMessageById(anchor.targetId))?.body;
        } else if (anchor.targetType == AnchorTargetType.note) {
          bodyBefore = (await db.getNoteById(anchor.targetId))?.content;
        }
        final removed = await AnchorService.instance.removeAnchor(anchor.id);
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
            if (bodyBefore != null) 'body': bodyBefore,
          },
        );

      case ToolNames.messageSetPriority:
        final msg = (await db.getMessageById(args['messageId'] as String))!;
        await db.updateMessagePriority([msg.id], args['priority'] as String);
        return (
          ProposalExecution(
              true, '已把消息「${msg.title}」标为 ${args['priority']}'),
          {'op': 'message.priority', 'messageId': msg.id, 'priority': msg.priority},
        );

      default:
        return (ProposalExecution(false, '无可执行的工具: $tool'), null);
    }
  }

  // ---- 撤销（逆操作） ----

  Future<void> _applyUndo(String tool, Map<String, dynamic> undo,
      Map<String, dynamic> payload) async {
    final db = AppDatabase.instance;
    switch (undo['op']) {
      case 'task.delete':
        await db.deleteTasks([undo['taskId'] as String]);
      case 'task.restore':
        await db
            .insertTask(Task.fromRow((undo['task'] as Map).cast<String, Object?>()));
        // v3 收尾：删除提案的快照含锚点行 + 受影响正文原文，撤销整体复原；
        // 旧快照无 'snapshot' 键（只恢复任务行）。
        final snapshot = undo['snapshot'];
        if (snapshot is Map) {
          await db.restoreTaskDeletionSnapshot(
              TaskDeletionSnapshot.fromJson(snapshot.cast<String, dynamic>()));
        }
      case 'note.delete':
        await db.deleteNote(undo['noteId'] as String);
      case 'note.content':
        final note = await db.getNoteById(undo['noteId'] as String);
        if (note != null) {
          await db.updateNote(note.copyWith(content: undo['content'] as String));
        }
      case 'anchor.remove':
        await AnchorService.instance.removeAnchor(undo['anchorId'] as String);
      case 'anchor.restore':
        final a = (undo['anchor'] as Map).cast<String, dynamic>();
        final targetType = a['target_type'] as String;
        final targetId = a['target_id'] as String;
        final body = undo['body'] as String?;
        if (body != null) {
          if (targetType == AnchorTargetType.message) {
            await db.updateMessageBody(targetId, body);
          } else if (targetType == AnchorTargetType.note) {
            final note = await db.getNoteById(targetId);
            if (note != null) {
              await db.updateNote(note.copyWith(content: body));
            }
          }
        }
        await db.insertAnchor(TaskAnchor(
          id: a['id'] as String,
          taskId: a['task_id'] as String,
          targetType: targetType,
          targetId: targetId,
          label: a['label'] as String?,
          createdBy: a['created_by'] as String,
          createdAt: (a['created_at'] as num).toInt(),
        ));
      case 'message.priority':
        await db.updateMessagePriority(
            [undo['messageId'] as String], undo['priority'] as String);
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

  /// note.replace_section：把 `heading`（markdown 标题文本，不含 #）界定的
  /// 区段正文替换为 [content]；标题行保留，区段到下一个同级或更高级标题为止。
  /// 找不到标题返回 null。
  static String? _replaceSection(
      String content, String heading, String replacement) {
    final lines = const LineSplitter().convert(content);
    final headingRe = RegExp(r'^(#{1,6})\s+(.*?)\s*$');
    var start = -1;
    var level = 0;
    for (var i = 0; i < lines.length; i++) {
      final m = headingRe.firstMatch(lines[i]);
      if (m != null && m.group(2) == heading) {
        start = i;
        level = m.group(1)!.length;
        break;
      }
    }
    if (start < 0) return null;
    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      final m = headingRe.firstMatch(lines[i]);
      if (m != null && m.group(1)!.length <= level) {
        end = i;
        break;
      }
    }
    final out = [
      ...lines.sublist(0, start + 1),
      if (replacement.isNotEmpty) ...const LineSplitter().convert(replacement),
      ...lines.sublist(end),
    ];
    return out.join('\n');
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
