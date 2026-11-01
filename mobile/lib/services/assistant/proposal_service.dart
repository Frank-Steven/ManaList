import 'package:uuid/uuid.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../database.dart';
import 'models.dart';
import 'proposal_executor.dart';
import 'tool_parser.dart';
import 'tool_spec.dart';
import 'tools/inbox_triage.dart';

/// 工具块处理结果（design-v3-details §2.3）。
sealed class ProposalOutcome {
  const ProposalOutcome();
}

/// 校验通过，提案已落待确认区（status=pending）。
class ProposalCreated extends ProposalOutcome {
  final ChangeProposal proposal;
  const ProposalCreated(this.proposal);
}

/// 流重试/重放命中去重键 (chatMessageId, blockIndex)，跳过落库。
class ProposalDuplicate extends ProposalOutcome {
  final ChangeProposal existing;
  const ProposalDuplicate(this.existing);
}

/// 校验失败：不落库，上层应回写对话一条 tool 错误消息，AI 可下轮重试。
class ProposalValidationFailure extends ProposalOutcome {
  final String reason;
  const ProposalValidationFailure(this.reason);
}

/// 只读工具直接执行的结果（details §2.2：结果回注对话为 tool 消息）。
class ReadToolResult extends ProposalOutcome {
  final String text;
  const ReadToolResult(this.text);
}

/// 提案服务（design-v3 §5.4）：工具调用块 → 校验 → 落 change_proposals。
///
/// 校验为每工具一份手写校验器（字段 + 目标存在性），不引入 schema 运行时。
/// 去重键 = (chatMessageId, blockIndex)：提案 id 直接取
/// `'<batchId>_b<blockIndex>'`（batchId 即 assistant 消息 id，details §3.1），
/// 重放同回合时命中主键即跳过。
class ProposalService {
  ProposalService._();

  static final ProposalService instance = ProposalService._();

  static const _uuid = Uuid();

  /// 提案 id（去重键的落库形式，details §2.3）。
  static String proposalIdFor(String batchId, int blockIndex) =>
      '${batchId}_b$blockIndex';

  /// 处理一个解析完成的工具块。
  ///
  /// [batchId] = 产出该块的 assistant chat_message id。
  Future<ProposalOutcome> handleToolBlock({
    required String conversationId,
    required String batchId,
    required ParsedToolBlock block,
  }) async {
    if (!block.ok) {
      return ProposalValidationFailure(block.parseError ?? '工具块解析失败');
    }
    final tool = block.tool!;
    final args = block.args!;
    final spec = toolSpecByName(tool);
    if (spec == null) {
      return ProposalValidationFailure('未知工具: $tool');
    }
    if (spec.reserved) {
      // 预留工具（当前无）：明确拒绝而不是静默忽略。
      return ProposalValidationFailure('工具 $tool 暂不可用（将在后续版本提供）');
    }

    final error = await validate(tool, args);
    if (error != null) return ProposalValidationFailure(error);

    if (spec.kind == ToolKind.read) {
      // inbox.triage 是提案生成器（details §4）：只读执行免审批，
      // 产出全部落待确认区（同一 batch_id），对话中回汇总文本。
      if (tool == ToolNames.inboxTriage) {
        final summary = await InboxTriage.instance.run(
          conversationId: conversationId,
          batchId: batchId,
          idPrefix: proposalIdFor(batchId, block.index),
          args: args,
        );
        return ReadToolResult(summary);
      }
      // 只读工具：无需审批，直接执行，结果由上层回注对话。
      final text = await ProposalExecutor.instance.executeReadTool(tool, args);
      return ReadToolResult(text);
    }

    final id = proposalIdFor(batchId, block.index);
    final db = AppDatabase.instance;
    final existing = await db.getProposalById(id);
    if (existing != null) return ProposalDuplicate(existing);

    final proposal = ChangeProposal(
      id: id,
      conversationId: conversationId,
      batchId: batchId,
      tool: tool,
      summary: summarize(tool, args),
      payload: args,
      status: ProposalStatus.pending,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insertProposal(proposal);
    return ProposalCreated(proposal);
  }

  // ---- 校验器（每工具一份手写，details §2.3） ----

  static const _taskPriorities = {
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor
  };
  static const _messagePriorities = {
    MessagePriority.red,
    MessagePriority.yellow,
    MessagePriority.green,
    MessagePriority.junk,
    MessagePriority.none
  };

  static String? _reqString(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is! String || v.trim().isEmpty) return '缺少必填参数: $key';
    return null;
  }

  static String? _optDate(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v == null) return null;
    if (v is! String || DateTime.tryParse(v.trim().replaceFirst(' ', 'T')) == null) {
      return '参数 $key 不是合法时间（应为 "YYYY-MM-DDTHH:mm"）';
    }
    return null;
  }

  static String? _optEnum(
          Map<String, dynamic> args, String key, Set<String> values) =>
      args[key] == null
          ? null
          : values.contains(args[key]) ? null : '参数 $key 取值非法: ${args[key]}';

  /// 字段 + 目标存在性校验；通过返回 null，否则返回失败原因。
  Future<String?> validate(String tool, Map<String, dynamic> args) async {
    final db = AppDatabase.instance;
    switch (tool) {
      case ToolNames.taskCreate:
        if (_reqString(args, 'title') != null) return _reqString(args, 'title');
        if (_optEnum(args, 'kind', {TaskKind.point, TaskKind.range}) != null) {
          return _optEnum(args, 'kind', {TaskKind.point, TaskKind.range});
        }
        if (_optEnum(args, 'priority', _taskPriorities) != null) {
          return _optEnum(args, 'priority', _taskPriorities);
        }
        if (_optDate(args, 'startAt') != null) return _optDate(args, 'startAt');
        if (_optDate(args, 'endAt') != null) return _optDate(args, 'endAt');
        if (args['kind'] == TaskKind.range && args['endAt'] == null) {
          return 'range 任务需要 endAt';
        }
        final parentId = args['parentId'];
        if (parentId != null &&
            (parentId is! String ||
                await db.getTaskById(parentId) == null)) {
          return '父任务不存在: $parentId';
        }
        return null;

      case ToolNames.taskUpdate:
        if (_reqString(args, 'id') != null) return _reqString(args, 'id');
        final task = await db.getTaskById(args['id'] as String);
        if (task == null) return '任务不存在: ${args['id']}';
        const mutable = {
          'title',
          'description',
          'kind',
          'startAt',
          'endAt',
          'priority',
          'status'
        };
        if (!args.keys.any(mutable.contains)) return '没有要修改的字段';
        if (args['title'] != null &&
            (args['title'] is! String ||
                (args['title'] as String).trim().isEmpty)) {
          return 'title 不能为空';
        }
        if (_optEnum(args, 'kind', {TaskKind.point, TaskKind.range}) != null) {
          return _optEnum(args, 'kind', {TaskKind.point, TaskKind.range});
        }
        if (_optEnum(args, 'priority', _taskPriorities) != null) {
          return _optEnum(args, 'priority', _taskPriorities);
        }
        if (_optEnum(args, 'status', {TaskStatus.active, TaskStatus.done}) !=
            null) {
          return _optEnum(args, 'status', {TaskStatus.active, TaskStatus.done});
        }
        if (_optDate(args, 'startAt') != null) return _optDate(args, 'startAt');
        if (_optDate(args, 'endAt') != null) return _optDate(args, 'endAt');
        return null;

      case ToolNames.taskDelete:
        if (_reqString(args, 'id') != null) return _reqString(args, 'id');
        if (await db.getTaskById(args['id'] as String) == null) {
          return '任务不存在: ${args['id']}';
        }
        return null;

      case ToolNames.taskList:
        if (_optEnum(args, 'status',
                {TaskStatus.active, TaskStatus.done, TaskStatus.archived}) !=
            null) {
          return _optEnum(args, 'status',
              {TaskStatus.active, TaskStatus.done, TaskStatus.archived});
        }
        final limit = args['limit'];
        if (limit != null && (limit is! num || limit < 1 || limit > 200)) {
          return 'limit 须为 1..200 的整数';
        }
        return null;

      case ToolNames.taskSearch:
      case ToolNames.librarySearch:
        if (_reqString(args, 'query') != null) return _reqString(args, 'query');
        if (tool == ToolNames.librarySearch) {
          final types = args['types'];
          if (types != null) {
            if (types is! List) return 'types 须为数组';
            for (final t in types) {
              if (!{
                ChatAttachmentType.note,
                ChatAttachmentType.message,
                ChatAttachmentType.file
              }.contains(t)) {
                return 'types 取值非法: $t';
              }
            }
          }
        }
        return null;

      case ToolNames.noteCreate:
        if (_reqString(args, 'title') != null) return _reqString(args, 'title');
        if (args['content'] != null && args['content'] is! String) {
          return 'content 须为文本';
        }
        final chapterId = args['chapterId'];
        if (chapterId != null) {
          if (chapterId is! String) return 'chapterId 须为文本';
          var found = false;
          for (final nb in await db.getNotebooks()) {
            for (final ch in await db.getChapters(nb.id)) {
              if (ch.id == chapterId) {
                found = true;
                break;
              }
            }
          }
          if (!found) return '章节不存在: $chapterId';
        }
        return null;

      case ToolNames.noteAppend:
        if (_reqString(args, 'noteId') != null) {
          return _reqString(args, 'noteId');
        }
        if (args['content'] is! String ||
            (args['content'] as String).isEmpty) {
          return '缺少必填参数: content';
        }
        if (await db.getNoteById(args['noteId'] as String) == null) {
          return '笔记不存在: ${args['noteId']}';
        }
        return null;

      case ToolNames.noteReplaceSection:
        if (_reqString(args, 'noteId') != null) {
          return _reqString(args, 'noteId');
        }
        if (_reqString(args, 'heading') != null) {
          return _reqString(args, 'heading');
        }
        if (args['content'] is! String) return '缺少必填参数: content';
        if (await db.getNoteById(args['noteId'] as String) == null) {
          return '笔记不存在: ${args['noteId']}';
        }
        return null;

      case ToolNames.noteRead:
        if (_reqString(args, 'noteId') != null) {
          return _reqString(args, 'noteId');
        }
        if (await db.getNoteById(args['noteId'] as String) == null) {
          return '笔记不存在: ${args['noteId']}';
        }
        return null;

      case ToolNames.anchorCreate:
        final targetType = args['targetType'];
        if (!{
          AnchorTargetType.note,
          AnchorTargetType.message,
          AnchorTargetType.file
        }.contains(targetType)) {
          return 'targetType 须为 note|message|file';
        }
        if (_reqString(args, 'targetId') != null) {
          return _reqString(args, 'targetId');
        }
        if (_reqString(args, 'taskId') != null) return _reqString(args, 'taskId');
        final targetId = args['targetId'] as String;
        final exists = switch (targetType) {
          AnchorTargetType.note => await db.getNoteById(targetId) != null,
          AnchorTargetType.message => await db.getMessageById(targetId) != null,
          _ => await db.getFileById(targetId) != null,
        };
        if (!exists) return '锚点目标不存在: $targetType/$targetId';
        if (await db.getTaskById(args['taskId'] as String) == null) {
          return '任务不存在: ${args['taskId']}';
        }
        if (targetType != AnchorTargetType.file) {
          final at = args['anchorText'];
          if (at is! String || at.isEmpty) {
            return '笔记/消息锚点需要 anchorText（正文定位文本）';
          }
        }
        return null;

      case ToolNames.anchorRemove:
        if (_reqString(args, 'anchorId') != null) {
          return _reqString(args, 'anchorId');
        }
        if (await db.getAnchorById(args['anchorId'] as String) == null) {
          return '锚点不存在: ${args['anchorId']}';
        }
        return null;

      case ToolNames.messageSetPriority:
        if (_reqString(args, 'messageId') != null) {
          return _reqString(args, 'messageId');
        }
        if (_optEnum(args, 'priority', _messagePriorities) != null) {
          return _optEnum(args, 'priority', _messagePriorities);
        }
        if (args['priority'] == null) return '缺少必填参数: priority';
        if (await db.getMessageById(args['messageId'] as String) == null) {
          return '消息不存在: ${args['messageId']}';
        }
        return null;

      case ToolNames.inboxTriage:
        return InboxTriage.validateScope(args);

      default:
        return '未知工具: $tool';
    }
  }

  /// 列表展示用的人类可读摘要（design-v3 §1.4 summary 列）。
  String summarize(String tool, Map<String, dynamic> args) {
    switch (tool) {
      case ToolNames.taskCreate:
        return '新建任务「${args['title']}」';
      case ToolNames.taskUpdate:
        final fields =
            args.keys.where((k) => k != 'id').join('、');
        return '修改任务 ${args['id']}（$fields）';
      case ToolNames.taskDelete:
        return '删除任务 ${args['id']}';
      case ToolNames.noteCreate:
        return '新建笔记「${args['title']}」';
      case ToolNames.noteAppend:
        return '向笔记 ${args['noteId']} 追加内容';
      case ToolNames.noteReplaceSection:
        return '替换笔记 ${args['noteId']} 的「${args['heading']}」区段';
      case ToolNames.anchorCreate:
        return '在 ${args['targetType']} ${args['targetId']} 上为任务 ${args['taskId']} 建锚点';
      case ToolNames.anchorRemove:
        return '移除锚点 ${args['anchorId']}';
      case ToolNames.messageSetPriority:
        return '把消息 ${args['messageId']} 标为 ${args['priority']}';
      default:
        return '$tool $args';
    }
  }

  /// 工具类型过滤 chip 的分类（details §3.2：任务/笔记/锚点/消息标记）。
  static String toolCategory(String tool) => switch (tool) {
        ToolNames.taskCreate ||
        ToolNames.taskUpdate ||
        ToolNames.taskDelete ||
        ToolNames.taskList ||
        ToolNames.taskSearch =>
          'task',
        ToolNames.noteCreate ||
        ToolNames.noteAppend ||
        ToolNames.noteReplaceSection ||
        ToolNames.noteRead =>
          'note',
        ToolNames.anchorCreate || ToolNames.anchorRemove => 'anchor',
        ToolNames.messageSetPriority => 'message',
        _ => 'other',
      };

  /// 待确认区默认勾选策略（details §3.3）：仅 message.set_priority(junk)
  /// 默认勾选，其余一律不勾选；通过动作仍须人工触发。
  static bool defaultSelected(ChangeProposal p) =>
      p.tool == ToolNames.messageSetPriority &&
      p.payload['priority'] == MessagePriority.junk;

  /// 新提案 id（非工具块路径的提案用，如阶段 7 的 inbox.triage 子提案）。
  String newProposalId() => _uuid.v4();
}
