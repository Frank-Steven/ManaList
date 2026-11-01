/// v2 任务模型，对应设计文档 §1.2 的 tasks 表。
///
/// 决策说明：v2 中事件与任务统一为 Task 实体——旧五类中的纯「时间点/时间段」
/// 与「时间点任务/时间段任务」合并，由 kind + start_at/end_at 可空覆盖全部五类。
class TaskKind {
  static const point = 'point';
  static const range = 'range';
}

class TaskPriority {
  static const important = 'important';
  static const normal = 'normal';
  static const minor = 'minor';
}

class TaskStatus {
  static const active = 'active';
  static const done = 'done';
  static const archived = 'archived';
}

/// 派生展示类型（由 kind + 时间得出，不落库）。
enum TaskDerivedType { plain, timePointTask, timeRangeTask }

class Task {
  final String id;
  final String title;
  final String? description;
  final String kind;

  /// 毫秒时间戳；null = 无时间任务（"我的待办"）。
  final int? startAt;
  final int? endAt;
  final String priority;
  final bool isAnnual;
  final String? sourceMessageId;

  /// 父任务（v2.2，可空，仅一级子任务）。
  final String? parentId;
  final String status;
  final int createdAt;
  final int updatedAt;

  const Task({
    required this.id,
    required this.title,
    this.description,
    required this.kind,
    this.startAt,
    this.endAt,
    this.priority = TaskPriority.normal,
    this.isAnnual = false,
    this.sourceMessageId,
    this.parentId,
    this.status = TaskStatus.active,
    required this.createdAt,
    required this.updatedAt,
  });

  TaskDerivedType get derivedType {
    if (startAt == null) return TaskDerivedType.plain;
    if (kind == TaskKind.range) return TaskDerivedType.timeRangeTask;
    return TaskDerivedType.timePointTask;
  }

  /// 与半开区间 [startMs, endMs) 是否有交集。startAt 为 null 返回 false；
  /// endAt 为 null 时按点处理（点落在区间内即相交）。
  bool overlaps(int startMs, int endMs) {
    final s = startAt;
    if (s == null) return false;
    // point 任务只有单个时刻：即使数据里残留 end_at 也按点处理（P1-1）
    final e = kind == TaskKind.point ? null : endAt;
    if (e == null) return s >= startMs && s < endMs;
    return s < endMs && e > startMs;
  }

  factory Task.fromRow(Map<String, Object?> row) => Task(
        id: row['id'] as String,
        title: row['title'] as String,
        description: row['description'] as String?,
        kind: row['kind'] as String,
        startAt: (row['start_at'] as num?)?.toInt(),
        endAt: (row['end_at'] as num?)?.toInt(),
        priority: row['priority'] as String,
        isAnnual: (row['is_annual'] as num? ?? 0) != 0,
        sourceMessageId: row['source_message_id'] as String?,
        parentId: row['parent_id'] as String?,
        status: row['status'] as String,
        createdAt: (row['created_at'] as num).toInt(),
        updatedAt: (row['updated_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'description': description,
        'kind': kind,
        'start_at': startAt,
        'end_at': endAt,
        'priority': priority,
        'is_annual': isAnnual ? 1 : 0,
        'source_message_id': sourceMessageId,
        'parent_id': parentId,
        'status': status,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  Task copyWith({
    String? id,
    String? title,
    String? Function()? description,
    String? kind,
    int? Function()? startAt,
    int? Function()? endAt,
    String? priority,
    bool? isAnnual,
    String? Function()? sourceMessageId,
    String? Function()? parentId,
    String? status,
    int? createdAt,
    int? updatedAt,
  }) =>
      Task(
        id: id ?? this.id,
        title: title ?? this.title,
        description: description != null ? description() : this.description,
        kind: kind ?? this.kind,
        startAt: startAt != null ? startAt() : this.startAt,
        endAt: endAt != null ? endAt() : this.endAt,
        priority: priority ?? this.priority,
        isAnnual: isAnnual ?? this.isAnnual,
        sourceMessageId: sourceMessageId != null
            ? sourceMessageId()
            : this.sourceMessageId,
        parentId: parentId != null ? parentId() : this.parentId,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
