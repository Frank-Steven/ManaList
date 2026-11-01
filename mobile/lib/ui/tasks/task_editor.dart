import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/text_width.dart';
import '../shared/segmented_selector.dart';

/// 任务编辑器结果：task 为保存后的任务；deleted=true 表示用户在编辑器内删除。
/// 返回 null = 用户取消。编辑器本身不写数据库，持久化与撤销注册由调用方负责。
///
/// 设定父任务导致父级范围扩大时（设计 §7 三选之一）：[parentExpanded] 为
/// 扩大范围后的父任务，[parentBefore] 为原父任务（供撤销恢复）。
class TaskEditorResult {
  final Task? task;
  final bool deleted;
  final Task? parentExpanded;
  final Task? parentBefore;

  const TaskEditorResult.save(this.task,
      {this.parentExpanded, this.parentBefore})
      : deleted = false;
  const TaskEditorResult.delete()
      : task = null,
        deleted = true,
        parentExpanded = null,
        parentBefore = null;
}

/// 任务编辑器（设计 §7）：半屏 modal，手动编辑全部字段。
///
/// - [existing] 非空 = 编辑已有任务；否则新建。
/// - seed* 为新建预填值；[sourceMessageId] 为非空时保存后由调用方负责与消息互链。
Future<TaskEditorResult?> showTaskEditor(
  BuildContext context, {
  Task? existing,
  String? seedTitle,
  String? seedDescription,
  String? sourceMessageId,
  int? seedStartAt,
  int? seedEndAt,
  String? seedKind,
}) {
  return showModalBottomSheet<TaskEditorResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _TaskEditorSheet(
      existing: existing,
      seedTitle: seedTitle,
      seedDescription: seedDescription,
      sourceMessageId: sourceMessageId,
      seedStartAt: seedStartAt,
      seedEndAt: seedEndAt,
      seedKind: seedKind,
    ),
  );
}

class _TaskEditorSheet extends StatefulWidget {
  final Task? existing;
  final String? seedTitle;
  final String? seedDescription;
  final String? sourceMessageId;
  final int? seedStartAt;
  final int? seedEndAt;
  final String? seedKind;

  const _TaskEditorSheet({
    this.existing,
    this.seedTitle,
    this.seedDescription,
    this.sourceMessageId,
    this.seedStartAt,
    this.seedEndAt,
    this.seedKind,
  });

  @override
  State<_TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<_TaskEditorSheet>
    with TickerProviderStateMixin {
  static const _maxTitleWidth = 20;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;

  /// 表单流转链（填完一项自动进入下一项）：标题 → 描述 → 类型/时间 →
  /// 优先级 → 保存。文本字段用 FocusNode 链；选择类字段不收键盘焦点，
  /// 只用 GlobalKey + Scrollable.ensureVisible 滚动/高亮，避免弹起键盘。
  final _titleFocus = FocusNode();
  final _descFocus = FocusNode();
  final _timeSectionKey = GlobalKey();
  final _prioritySectionKey = GlobalKey();
  final _saveButtonKey = GlobalKey();

  /// 流转到位后的轻提示：目标区块底色呼吸一次、保存按钮缩放呼吸一次。
  late final AnimationController _flashCtrl;
  GlobalKey? _flashTarget;
  late final AnimationController _savePulseCtrl;
  late String _kind;
  DateTime? _startAt;
  DateTime? _endAt;
  late String _priority;
  late bool _isAnnual;
  String? _sourceMessageId;
  Message? _sourceMessage;
  bool _sourceLoaded = false;

  /// 父任务（设计 §7，v2.2）：可空，仅一级；候选在 initState 加载。
  String? _parentId;
  List<Task> _parentCandidates = [];

  bool get _isEditing => widget.existing != null;

  static DateTime? _fromMs(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _titleCtrl =
        TextEditingController(text: e?.title ?? widget.seedTitle ?? '');
    _descCtrl = TextEditingController(
        text: e?.description ?? widget.seedDescription ?? '');
    _kind = e?.kind ?? widget.seedKind ?? TaskKind.point;
    _startAt = _fromMs(e?.startAt ?? widget.seedStartAt);
    _endAt = _fromMs(e?.endAt ?? widget.seedEndAt);
    _priority = e?.priority ?? TaskPriority.normal;
    _isAnnual = e?.isAnnual ?? false;
    _sourceMessageId = widget.sourceMessageId ?? e?.sourceMessageId;
    _parentId = e?.parentId;
    _flashCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _savePulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
    _titleCtrl.addListener(() => setState(() {}));
    _loadSourceMessage();
    _loadParentCandidates();
  }

  /// 父任务候选（设计 §7）：尺度不小于本任务、排除自身/已有父级的任务
  /// （仅一级，已有父级者不能再作父）、is_annual 年度重复任务（范围语义
  /// 逐年平移，不宜作父）。尺度随时间编辑实时变化，尺度过滤在下拉时进行。
  Future<void> _loadParentCandidates() async {
    final tasks =
        await AppDatabase.instance.getTasks(status: TaskStatus.active);
    if (!mounted) return;
    setState(() {
      _parentCandidates = tasks
          .where((t) =>
              t.id != widget.existing?.id && t.parentId == null && !t.isAnnual)
          .toList();
      if (_parentId != null &&
          !_parentCandidates.any((t) => t.id == _parentId)) {
        _parentId = null;
      }
    });
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _titleFocus.dispose();
    _descFocus.dispose();
    _flashCtrl.dispose();
    _savePulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSourceMessage() async {
    final id = _sourceMessageId;
    if (id == null) return;
    final msg = await AppDatabase.instance.getMessageById(id);
    if (mounted) {
      setState(() {
        _sourceMessage = msg;
        _sourceLoaded = true;
      });
    }
  }

  int get _titleWidth => displayWidth(_titleCtrl.text);

  bool get _canSave =>
      _titleCtrl.text.trim().isNotEmpty && _titleWidth <= _maxTitleWidth;

  void _switchKind(int index) {
    final kind = index == 0 ? TaskKind.point : TaskKind.range;
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      // 切到时间段时补默认结束时间（开始 +1 小时）；已填时间一律保留
      if (kind == TaskKind.range && _startAt != null && _endAt == null) {
        _endAt = _startAt!.add(const Duration(hours: 1));
      }
    });
  }

  Future<void> _pickDate(bool isStart) async {
    final current = isStart ? _startAt : _endAt;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    if (!mounted) return; // P3-5：await 之后页面可能已销毁
    setState(() {
      final merged = DateTime(picked.year, picked.month, picked.day,
          current?.hour ?? 9, current?.minute ?? 0);
      if (isStart) {
        _startAt = merged;
      } else {
        _endAt = merged;
      }
    });
    _onTimePicked();
  }

  Future<void> _pickTime(bool isStart) async {
    final current = isStart ? _startAt : _endAt;
    if (current == null) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (picked == null) return;
    if (!mounted) return; // P3-5：await 之后页面可能已销毁
    setState(() {
      final merged = DateTime(current.year, current.month, current.day,
          picked.hour, picked.minute);
      if (isStart) {
        _startAt = merged;
      } else {
        _endAt = merged;
      }
    });
    _onTimePicked();
  }

  void _clearTime() {
    setState(() {
      _startAt = null;
      _endAt = null;
    });
  }

  /// 流转到下一字段：滚动到目标区块，可附带底色呼吸一次。
  /// 选择类字段不请求键盘焦点，保证不打断用户的选择操作。
  void _advanceTo(GlobalKey key, {bool flash = false}) {
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
    if (flash) {
      setState(() => _flashTarget = key);
      _flashCtrl.forward(from: 0);
    }
  }

  /// 标题回车/完成 → 焦点移到描述。
  void _onTitleSubmitted() => _descFocus.requestFocus();

  /// 描述完成 → 收起键盘，滚动并高亮类型/时间选择区。
  void _onDescSubmitted() {
    FocusScope.of(context).unfocus();
    _advanceTo(_timeSectionKey, flash: true);
  }

  /// 时间选完（点确定后）→ 滚动并高亮优先级选择区。
  void _onTimePicked() => _advanceTo(_prioritySectionKey, flash: true);

  /// 优先级选完 → 滚动到底部保存按钮并呼吸一次（不打扰式提示）。
  void _onPriorityChanged(int i) {
    setState(() {
      _priority = switch (i) {
        0 => TaskPriority.important,
        2 => TaskPriority.minor,
        _ => TaskPriority.normal,
      };
    });
    _advanceTo(_saveButtonKey);
    _savePulseCtrl.forward(from: 0);
  }

  /// 区块高亮包裹：流转到位后底色呼吸一次（sin 半周期 0→1→0）。
  Widget _flashWrap(GlobalKey key, Widget child) {
    return AnimatedBuilder(
      animation: _flashCtrl,
      builder: (context, child) {
        final t = _flashTarget == key
            ? math.sin(math.pi * _flashCtrl.value)
            : 0.0;
        return Container(
          key: key,
          decoration: BoxDecoration(
            color: t <= 0
                ? null
                : Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.45 * t),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        );
      },
      child: child,
    );
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: const Text('确定删除该任务吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(const TaskEditorResult.delete());
    }
  }

  void _showSourceDialog() {
    final msg = _sourceMessage;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(msg?.title ?? '来源消息'),
        content: SingleChildScrollView(
            child: Text(msg == null ? '原文已不存在' : msg.body)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 父任务下拉：尺度随时间编辑实时变化，候选按当前尺度过滤
  /// （父尺度 ≥ 子尺度；不定时子任务可选任意候选）。
  Widget _parentDropdown() {
    final childRank = timeScaleRank(
        deriveTimeScale(_startAt, _kind == TaskKind.range ? _endAt : null));
    final eligible = _parentCandidates
        .where((t) =>
            timeScaleRank(deriveTaskScale(t.startAt, t.endAt, kind: t.kind)) >=
                  childRank)
        .toList();
    final value =
        eligible.any((t) => t.id == _parentId) ? _parentId : null;
    return DropdownButton<String?>(
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        const DropdownMenuItem(value: null, child: Text('无')),
        for (final t in eligible)
          DropdownMenuItem(
            value: t.id,
            child: Text(
              '${t.title}（${timeScaleLabel(deriveTaskScale(t.startAt, t.endAt, kind: t.kind))}）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => setState(() => _parentId = v),
    );
  }

  /// 范围不符时的三选对话框（设计 §7）：扩大父级范围 / 缩小本级范围 / 取消。
  Future<String?> _chooseRangeFix() {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('范围超出父任务'),
        content: const Text('子任务的时间范围需包含在父任务范围内。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('shrink'),
              child: const Text('缩小本级范围')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop('expand'),
              child: const Text('扩大父级范围')),
        ],
      ),
    );
  }

  void _snack(String text) {
    if (!mounted) return; // P3-5：await 之后调用时页面可能已销毁
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(text), duration: const Duration(seconds: 2)));
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty || displayWidth(title) > _maxTitleWidth) return;
    var start = _startAt;
    DateTime? end = _kind == TaskKind.range ? _endAt : null;
    var kind = _kind;
    if (start == null) {
      end = null;
    } else if (kind == TaskKind.range) {
      end ??= start.add(const Duration(hours: 1));
      if (!end.isAfter(start)) {
        _snack('结束时间需晚于开始时间');
        return;
      }
    }

    // 父任务约束（设计 §7，v2.2）：子尺度 ≤ 父尺度；双方有时间时
    // 子范围必须 ⊂ 父范围，不符则三选；父不定时则子必须不定时。
    Task? parentExpanded;
    Task? parentBefore;
    var parentId = _parentId;
    if (parentId != null) {
      final candidates =
          _parentCandidates.where((t) => t.id == parentId).toList();
      if (candidates.isEmpty) {
        parentId = null; // 候选已被删除/失效
      } else {
        final parent = candidates.first;
        final parentRank =
            timeScaleRank(
                  deriveTaskScale(parent.startAt, parent.endAt, kind: parent.kind));
        final childRank = timeScaleRank(
            deriveTimeScale(start, kind == TaskKind.range ? end : null));
        if (childRank > parentRank) {
          _snack('子任务尺度不能大于父任务尺度');
          return;
        }
        final psMs = parent.startAt;
        if (psMs == null && start != null) {
          _snack('不定时父任务的子任务也必须是不定时');
          return;
        }
        if (psMs != null && start != null) {
          final peMs = parent.endAt ?? psMs;
          var csMs = start.millisecondsSinceEpoch;
          var ceMs =
              kind == TaskKind.range ? end!.millisecondsSinceEpoch : csMs;
          if (csMs < psMs || ceMs > peMs) {
            final choice = await _chooseRangeFix();
            if (!mounted) return;
            if (choice == null || choice == 'cancel') return; // 中止保存
            if (choice == 'expand') {
              parentBefore = parent;
              final ns = csMs < psMs ? csMs : psMs;
              final ne = ceMs > peMs ? ceMs : peMs;
              final staysPoint =
                  parent.kind == TaskKind.point && ns == ne;
              parentExpanded = parent.copyWith(
                kind: staysPoint ? TaskKind.point : TaskKind.range,
                startAt: () => ns,
                endAt: () => staysPoint ? null : ne,
              );
            } else {
              // 缩小本级：钳进父范围；父为点任务或钳后退化时本级变点
              csMs = csMs.clamp(psMs, peMs);
              ceMs = ceMs.clamp(psMs, peMs);
              if (ceMs <= csMs || parent.kind == TaskKind.point) {
                start = DateTime.fromMillisecondsSinceEpoch(csMs);
                end = null;
                kind = TaskKind.point;
              } else {
                start = DateTime.fromMillisecondsSinceEpoch(csMs);
                end = DateTime.fromMillisecondsSinceEpoch(ceMs);
              }
            }
          }
        }
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final e = widget.existing;
    final desc = _descCtrl.text.trim();
    final task = Task(
      id: e?.id ?? const Uuid().v4(),
      title: title,
      description: desc.isEmpty ? null : desc,
      kind: kind,
      startAt: start?.millisecondsSinceEpoch,
      endAt: end?.millisecondsSinceEpoch,
      priority: _priority,
      isAnnual: _isAnnual,
      sourceMessageId: _sourceMessageId,
      status: e?.status ?? TaskStatus.active,
      createdAt: e?.createdAt ?? now,
      updatedAt: now,
      parentId: parentId,
    );
    Navigator.of(context).pop(TaskEditorResult.save(task,
        parentExpanded: parentExpanded, parentBefore: parentBefore));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final widthOver = _titleWidth > _maxTitleWidth;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_isEditing ? '编辑任务' : '新建任务',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            TextField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              autofocus: !_isEditing,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _onTitleSubmitted(),
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '必填',
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: (_titleWidth / _maxTitleWidth).clamp(0.0, 1.0),
                    color: widthOver ? scheme.error : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$_titleWidth/$_maxTitleWidth',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        widthOver ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              focusNode: _descFocus,
              minLines: 2,
              maxLines: 5,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _onDescSubmitted(),
              decoration: const InputDecoration(
                labelText: '描述',
                hintText: '可选',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            _flashWrap(
              _timeSectionKey,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('类型', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SegmentedSelector<int>(
                    values: const [0, 1],
                    labels: const ['时间点', '时间段'],
                    height: 36,
                    selected: _kind == TaskKind.point ? 0 : 1,
                    onChanged: _switchKind,
                  ),
                  const SizedBox(height: 12),
                  _TimeRow(
                    label: '开始',
                    value: _startAt,
                    onPickDate: () => _pickDate(true),
                    onPickTime: () => _pickTime(true),
                    onClear: _clearTime,
                  ),
                  if (_kind == TaskKind.range)
                    _TimeRow(
                      label: '结束',
                      value: _endAt,
                      onPickDate: () => _pickDate(false),
                      onPickTime: () => _pickTime(false),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _flashWrap(
              _prioritySectionKey,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('优先级',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SegmentedSelector<int>(
                    values: const [0, 1, 2],
                    labels: const ['重要', '一般', '不重要'],
                    dots: const [Colors.red, Colors.amber, Colors.green],
                    height: 36,
                    selected: switch (_priority) {
                      TaskPriority.important => 0,
                      TaskPriority.minor => 2,
                      _ => 1,
                    },
                    onChanged: _onPriorityChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 尺度（设计 §7，v2.1）：只读展示当前派生时间尺度，随时间选择实时变化
            Row(
              children: [
                Text('尺度', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 12),
                Text(
                  timeScaleLabel(deriveTimeScale(
                    _startAt,
                    _kind == TaskKind.range ? _endAt : null,
                  )),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 父任务（设计 §7，v2.2）：候选 = 尺度不小于本任务的任务，
            // 排除自身/已有父级/年度重复任务；仅一级。
            Row(
              children: [
                Text('父任务', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 12),
                Expanded(child: _parentDropdown()),
              ],
            ),
            if (_sourceMessageId != null)
              Card(
                margin: const EdgeInsets.only(top: 4),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.message_outlined),
                  title: Text(
                    !_sourceLoaded
                        ? '来源消息加载中…'
                        : (_sourceMessage?.title ?? '来源消息（原文已不存在）'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('点击查看原文'),
                  onTap: _showSourceDialog,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_isEditing)
                  TextButton.icon(
                    onPressed: _confirmDelete,
                    icon: Icon(Icons.delete_outline, color: scheme.error),
                    label:
                        Text('删除', style: TextStyle(color: scheme.error)),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                // 优先级选完后呼吸一次（轻提示，不弹 SnackBar 打扰）
                AnimatedBuilder(
                  animation: _savePulseCtrl,
                  builder: (context, child) => Transform.scale(
                    scale:
                        1 + 0.07 * math.sin(math.pi * _savePulseCtrl.value),
                    child: child,
                  ),
                  child: FilledButton(
                    key: _saveButtonKey,
                    onPressed: _canSave ? _save : null,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final VoidCallback? onClear;

  const _TimeRow({
    required this.label,
    required this.value,
    required this.onPickDate,
    required this.onPickTime,
    this.onClear,
  });

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String fmtDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          TextButton(
            onPressed: onPickDate,
            child: Text(v == null ? '选择日期' : fmtDate(v)),
          ),
          TextButton(
            onPressed: v == null ? null : onPickTime,
            child: Text(v == null ? '--:--' : fmtTime(v)),
          ),
          const Spacer(),
          if (onClear != null && v != null)
            IconButton(
              tooltip: '清除时间（变为无时间任务）',
              visualDensity: VisualDensity.compact,
              onPressed: onClear,
              icon: Icon(Icons.clear, size: 18, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
