import 'dart:convert';

/// 助理（Assistant）契约层模型，与 shared/schemas 对齐：
/// task-anchor / chat-request / chat-response / model-config，
/// 以及待确认区 change_proposals（design-v3 §1.4）。
///
/// 仅类型与纯函数，不接 UI、不动 database.dart。

// ---- 任务锚点（task-anchor.schema.json，design-v3 §1.1） ----

/// 锚点行内 marker 正则，全项目唯一事实源（design-v3-details §1.1）。
/// 语法：⟦task:<uuid>⟧，<uuid> 即 task_anchors.id，小写写入、读取大小写容忍。
final RegExp anchorMarkerPattern = RegExp(
    r'⟦task:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})⟧');

/// 生成锚点 marker 文本。
String anchorMarker(String anchorId) => '⟦task:$anchorId⟧';

/// 剥离正文中全部锚点 marker（design-v3-details §1.4）。
/// 参与去重/哈希的文本必须先剥离；不做空白折叠。
String stripAnchorMarkers(String text) =>
    text.replaceAll(anchorMarkerPattern, '');

class AnchorTargetType {
  static const message = 'message';

  /// 笔记章节（anchors-v2.md §2：对象级锚点，锚到整章）。
  static const chapter = 'chapter';
  static const file = 'file';

  /// v12 前的行内 marker 锚点目标（单篇笔记）。仅迁移/兼容读取用。
  static const note = 'note';
}

class AnchorCreatedBy {
  static const user = 'user';
  static const ai = 'ai';
}

/// 任务锚点：连接一个任务与库中消息/笔记/文件（design-v3 §1.1 task_anchors 表）。
class TaskAnchor {
  final String id;
  final String taskId;
  final String targetType;
  final String targetId;

  /// 锚点显示名；null 时取任务标题快照。
  final String? label;
  final String createdBy;

  /// Unix 毫秒时间戳。
  final int createdAt;

  const TaskAnchor({
    required this.id,
    required this.taskId,
    required this.targetType,
    required this.targetId,
    this.label,
    required this.createdBy,
    required this.createdAt,
  });

  factory TaskAnchor.fromJson(Map<String, dynamic> json) => TaskAnchor(
        id: json['id'] as String,
        taskId: json['taskId'] as String,
        targetType: json['targetType'] as String,
        targetId: json['targetId'] as String,
        label: json['label'] as String?,
        createdBy: json['createdBy'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'taskId': taskId,
        'targetType': targetType,
        'targetId': targetId,
        if (label != null) 'label': label,
        'createdBy': createdBy,
        'createdAt': createdAt,
      };
}

// ---- 对话请求（chat-request.schema.json，design-v3 §2、§6.3） ----

class ChatRole {
  static const user = 'user';
  static const assistant = 'assistant';

  /// 工具/提案执行结果回注的消息。
  static const tool = 'tool';
}

class ChatAttachmentType {
  static const note = 'note';
  static const message = 'message';
  static const file = 'file';
}

/// 对话附件。content 为 null 时仅是库实体引用（消息级 attachments）；
/// 非 null 为展开后的正文块（请求顶层 attachments，带 [#note:标题] 引用头）。
/// 图片附件（vision 模型）额外携带缩放后的内联图像（[dataBase64]，PNG）。
class ChatAttachment {
  final String type;
  final String id;
  final String? content;

  /// 文件附件的 MIME 类型（图片附件展开时写入，如 image/png）。
  final String? mimeType;

  /// 图片附件的内联图像（base64 PNG，已按多模态输入缩放）；
  /// 仅当目标模型声明 vision=true 时填充。
  final String? dataBase64;

  const ChatAttachment({
    required this.type,
    required this.id,
    this.content,
    this.mimeType,
    this.dataBase64,
  });

  factory ChatAttachment.fromJson(Map<String, dynamic> json) => ChatAttachment(
        type: json['type'] as String,
        id: json['id'] as String,
        content: json['content'] as String?,
        mimeType: json['mimeType'] as String?,
        dataBase64: json['dataBase64'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        if (content != null) 'content': content,
        if (mimeType != null) 'mimeType': mimeType,
        if (dataBase64 != null) 'dataBase64': dataBase64,
      };
}

/// B15（2026-11-03）：从对话附件里取出「用户选中的消息 id」。
///
/// 只保留 `type == message` 的库实体引用（笔记/文件附件不参与消息范围），
/// 去重并保持原顺序 —— triage 的候选范围以此为准。
List<String> selectedMessageIdsOf(Iterable<ChatAttachment> attachments) {
  final out = <String>[];
  final seen = <String>{};
  for (final a in attachments) {
    if (a.type != ChatAttachmentType.message) continue;
    if (a.id.isEmpty) continue;
    if (seen.add(a.id)) out.add(a.id);
  }
  return out;
}

/// 对话消息（chat_messages 表 / chat-request messages[]）。
class ChatMessageModel {
  final String role;
  final String content;

  /// 该消息引用的库实体（仅引用，content 为 null）。
  final List<ChatAttachment> attachments;

  const ChatMessageModel({
    required this.role,
    required this.content,
    this.attachments = const [],
  });

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) =>
      ChatMessageModel(
        role: json['role'] as String,
        content: json['content'] as String,
        attachments: ((json['attachments'] as List?) ?? const [])
            .map((e) => ChatAttachment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((e) => e.toJson()).toList(),
      };
}

// ---- 流式事件（chat-response.schema.json，design-v3 §2、§5.4） ----

/// /v1/chat 流式事件。desktop 只透传 token 流、不解析不执行工具；
/// 工具调用块由手机端 tool_parser 解析后落提案。
sealed class ChatEvent {
  const ChatEvent();

  factory ChatEvent.fromJson(Map<String, dynamic> json) {
    switch (json['type'] as String) {
      case 'token_delta':
        return ChatTokenDelta(json['delta'] as String);
      case 'reasoning_delta':
        return ChatReasoningDelta(json['delta'] as String);
      case 'proposal':
        return ChatProposalEvent(
          proposalId: json['proposalId'] as String,
          tool: json['tool'] as String,
          args: (json['args'] as Map).cast<String, dynamic>(),
        );
      case 'done':
        return const ChatDone();
      case 'error':
        return ChatError(json['error'] as String);
      default:
        throw FormatException('未知 ChatEvent 类型: ${json['type']}');
    }
  }

  static ChatEvent parseLine(String line) =>
      ChatEvent.fromJson(jsonDecode(line) as Map<String, dynamic>);

  Map<String, dynamic> toJson();
}

/// 增量 token（模型原始输出透传，可含 ```tool 工具块片段）。
class ChatTokenDelta extends ChatEvent {
  final String delta;
  const ChatTokenDelta(this.delta);

  @override
  Map<String, dynamic> toJson() => {'type': 'token_delta', 'delta': delta};
}

/// 推理内容增量（reasoning_content / reasoning）。
/// 与正文分开：不进 tool_parser，直接作为「思考」段展示（2026-11-13）。
class ChatReasoningDelta extends ChatEvent {
  final String delta;
  const ChatReasoningDelta(this.delta);

  @override
  Map<String, dynamic> toJson() => {'type': 'reasoning_delta', 'delta': delta};
}

/// 原子工具调用提案事件：proposalId 由客户端生成，对应 change_proposals 落库。
class ChatProposalEvent extends ChatEvent {
  final String proposalId;
  final String tool;
  final Map<String, dynamic> args;

  const ChatProposalEvent({
    required this.proposalId,
    required this.tool,
    required this.args,
  });

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'proposal', 'proposalId': proposalId, 'tool': tool, 'args': args};
}

class ChatDone extends ChatEvent {
  const ChatDone();

  @override
  Map<String, dynamic> toJson() => {'type': 'done'};
}

class ChatError extends ChatEvent {
  final String error;
  const ChatError(this.error);

  @override
  Map<String, dynamic> toJson() => {'type': 'error', 'error': error};
}

// ---- 模型配置（model-config.schema.json，design-v3 §6.2） ----

class ModelProvider {
  static const openaiCompat = 'openai-compat';
  static const mock = 'mock';
}

/// 模型配置。Ollama 暂缓，provider 暂只列 openai-compat / mock。
class ModelConfig {
  final String id;
  final String name;
  final String provider;
  final String baseUrl;
  final String model;

  /// API key 所在环境变量名，不直接存密钥。
  final String? apiKeyEnv;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.model,
    this.apiKeyEnv,
  });

  factory ModelConfig.fromJson(Map<String, dynamic> json) => ModelConfig(
        id: json['id'] as String,
        name: json['name'] as String,
        provider: json['provider'] as String,
        baseUrl: json['baseUrl'] as String,
        model: json['model'] as String,
        apiKeyEnv: json['apiKeyEnv'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'baseUrl': baseUrl,
        'model': model,
        if (apiKeyEnv != null) 'apiKeyEnv': apiKeyEnv,
      };
}

// ---- 变更提案（change_proposals 表，design-v3 §1.4、details §3.1） ----

class ProposalStatus {
  static const pending = 'pending';
  static const approved = 'approved';
  static const rejected = 'rejected';
  static const applied = 'applied';
  static const failed = 'failed';

  /// 被并发修改覆盖而未执行（crdt.md §3.2）：不是错误，
  /// 卡片提供「以当前状态重新提交」入口。
  static const superseded = 'superseded';
}

/// 待确认区的一条原子变更提案：AI 写工具调用的落点，人工审批后执行。
class ChangeProposal {
  final String id;

  /// 来源对话；删除对话后置 null（提案独立存在）。
  final String? conversationId;

  /// 产出该提案的 assistant 消息 id；同回合提案为一组。
  final String? batchId;

  /// 原子工具名，如 task.create。
  final String tool;

  /// 人类可读摘要（列表展示用）。
  final String summary;

  /// 原子变更的完整参数，审批通过后据此执行。
  final Map<String, dynamic> payload;
  final String status;
  final int createdAt;
  final int? resolvedAt;

  const ChangeProposal({
    required this.id,
    this.conversationId,
    this.batchId,
    required this.tool,
    required this.summary,
    required this.payload,
    this.status = ProposalStatus.pending,
    required this.createdAt,
    this.resolvedAt,
  });

  factory ChangeProposal.fromJson(Map<String, dynamic> json) =>
      ChangeProposal(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String?,
        batchId: json['batchId'] as String?,
        tool: json['tool'] as String,
        summary: json['summary'] as String,
        payload: (json['payload'] as Map).cast<String, dynamic>(),
        status: json['status'] as String? ?? ProposalStatus.pending,
        createdAt: (json['createdAt'] as num).toInt(),
        resolvedAt: (json['resolvedAt'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (conversationId != null) 'conversationId': conversationId,
        if (batchId != null) 'batchId': batchId,
        'tool': tool,
        'summary': summary,
        'payload': payload,
        'status': status,
        'createdAt': createdAt,
        if (resolvedAt != null) 'resolvedAt': resolvedAt,
      };
}
