/// CRDT 纯函数层（crdt.md §2/§4）：actor 决胜序与 LWW 比较键。
///
/// 本文件只有类型与纯函数，不接 UI、不动 database.dart；
/// op 的落库与物化见 database.dart 的 op_log 部分。
library;

/// actor 标识（crdt.md §2.1）。
class OpActor {
  /// 人的一切手动操作。
  static const user = 'user';

  /// 采集入库、迁移、归档联动等非交互写入。
  static const system = 'system';

  /// 某对话的助理（提案审批通过后，以该对话身份落 op）。
  static String assistant(String conversationId) => 'assistant:$conversationId';

  /// 是否为助理 actor（`assistant:<conversation_id>`）。
  static bool isAssistant(String actor) => actor.startsWith('assistant:');
}

/// op 种类（crdt.md §2.2）。
class OpKind {
  /// LWW-Register 赋值（任务字段、消息优先级、笔记正文等）。
  static const lwwSet = 'lww_set';

  /// OR-Set 添加（锚点）。
  static const orAdd = 'or_add';

  /// OR-Set 移除（只移除生成时观察到的 tag 集）。
  static const orRemove = 'or_remove';

  /// 追加集元素（note.append 的追加段）。
  static const append = 'append';

  /// LWW 墓碑（任务删除）。
  static const tombstone = 'tombstone';
}

/// LWW 比较键 (lamport, actor, opId)（crdt.md §4.1）。
class OpStamp {
  final int lamport;
  final String actor;
  final String opId;

  const OpStamp({required this.lamport, required this.actor, required this.opId});

  factory OpStamp.fromJson(Map<String, dynamic> json) => OpStamp(
        lamport: (json['lamport'] as num).toInt(),
        actor: json['actor'] as String,
        opId: json['opId'] as String? ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'lamport': lamport, 'actor': actor, 'opId': opId};

  @override
  bool operator ==(Object other) =>
      other is OpStamp &&
      other.lamport == lamport &&
      other.actor == actor &&
      other.opId == opId;

  @override
  int get hashCode => Object.hash(lamport, actor, opId);
}

/// 确定性决胜序（crdt.md §2.1）：`user` > `system` > `assistant:*`。
/// 人永远赢同刻冲突——这是规则，不是启发式。
int actorRank(String actor) => switch (actor) {
      OpActor.user => 3,
      OpActor.system => 2,
      _ => 1, // assistant:* 同级
    };

/// LWW 比较：candidate 是否赢过 current（current 为 null 时必赢）。
/// 比较键序：lamport → actor 决胜序 → actor 字典序 → opId。
bool lwwWins(OpStamp candidate, OpStamp? current) {
  if (current == null) return true;
  if (candidate.lamport != current.lamport) {
    return candidate.lamport > current.lamport;
  }
  final r = actorRank(candidate.actor) - actorRank(current.actor);
  if (r != 0) return r > 0;
  if (candidate.actor != current.actor) {
    return candidate.actor.compareTo(current.actor) > 0;
  }
  return candidate.opId.compareTo(current.opId) > 0;
}

/// 目标寻址串（crdt.md §2.2 target 列）。
String taskFieldTarget(String taskId, String field) => 'tasks:$taskId:$field';
String taskPrefix(String taskId) => 'tasks:$taskId:';
String messageFieldTarget(String messageId, String field) =>
    'messages:$messageId:$field';
String noteFieldTarget(String noteId, String field) => 'notes:$noteId:$field';
String anchorSetTarget(String taskId) => 'anchors:$taskId';
