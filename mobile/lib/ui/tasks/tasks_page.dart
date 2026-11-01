import 'package:flutter/material.dart';

import '../../services/app_ui_state.dart';
import 'task_list_view.dart';
import 'task_schedule_view.dart';

/// 任务页（design-v3 §4，v3 阶段 4）：合并原「待办」与「日程」两页，
/// 顶部视图切换「列表 / 日 / 月 / 年 / 年度」，数据同源 tasks 表，各视图按
/// 时间尺度（deriveTaskScale / scalesForView）过滤。
///
/// ui-structure §3/§6.2 收编后：整屏唯一 AppBar 由本页持有（标题「任务」），
/// 两个内嵌视图不再带 AppBar；视图级操作上收 AppBar actions 并按当前视图
/// 分显隐（甘特模式的「现在」定位）；列表视图的多选态降级为内容首行工具条。
/// 视图切换器与库页一致收进 AppBar.bottom 的 TabBar；当前视图经
/// [AppUiState.tasksViewMode] 持久化（首次默认「列表」），启动时恢复。
///
/// - 列表 = 原待办页（[TaskListView]：尺度页签 + 多选 + 内嵌详情）；
/// - 日/月/年/年度 = 原日程页对应粒度（[TaskScheduleView]，粒度由本页下发，
///   年度档 = granularity 0 的 YearlyView；视图内下钻（点月份/日期/年份）
///   经 onSwitchGranularity 回本页换 mode）。
/// - 甘特视图懒构建：首次切到才创建（与壳层 _builtTabs 同一策略）。
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => TasksPageState();
}

class TasksPageState extends State<TasksPage>
    with SingleTickerProviderStateMixin {
  /// 0=列表 1=日 2=月 3=年 4=年度
  int _mode = 0;

  late final TabController _tab;

  static const _granularityForMode = {1: 3, 2: 2, 3: 1, 4: 0};
  static const _modeForGranularity = {3: 1, 2: 2, 1: 3, 0: 4};

  final _listKey = GlobalKey<TaskListViewState>();
  final _scheduleKey = GlobalKey<TaskScheduleViewState>();

  /// 甘特视图是否已创建（未访问过的模式不构建）。
  bool _scheduleBuilt = false;

  /// 列表视图处于多选态时隐藏 FAB（避免遮挡底部批量操作条）。
  bool _listSelecting = false;

  @override
  void initState() {
    super.initState();
    _mode = AppUiState.instance.tasksViewMode;
    _scheduleBuilt = _mode != 0;
    _tab = TabController(length: 5, vsync: this, initialIndex: _mode);
    _tab.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    // 点击即切：_tab.index 在指示器动画起跑时已指向目标档，内容过渡
    // （AnimatedSwitcher 300ms）与指示器动画同步进行；原先等动画播完
    // （indexIsChanging 归位）才切，内容滞后一拍。
    if (_tab.index != _mode) _switchMode(_tab.index);
  }

  /// 壳层切页时刷新：列表始终刷新；甘特视图仅在已构建时刷新。
  Future<void> reload() async {
    await _listKey.currentState?.reload();
    if (_scheduleBuilt) await _scheduleKey.currentState?.reload();
  }

  void _switchMode(int mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      if (mode != 0) _scheduleBuilt = true;
    });
    if (_tab.index != mode) _tab.animateTo(mode);
    AppUiState.instance.setTasksViewMode(mode);
  }

  /// 甘特视图内部下钻/详情跳转需要换粒度时回调（年度=0 年=1 月=2 日=3）。
  void _switchGranularity(int g) {
    final mode = _modeForGranularity[g];
    if (mode != null) _switchMode(mode);
  }

  /// FAB 新建任务（ui-structure §4：领域主创建统一 FAB，复用任务编辑器）。
  /// 编辑器返回后列表与甘特（若已构建）都刷新。
  Future<void> _createTask() async {
    await _listKey.currentState?.createTask();
    if (_scheduleBuilt) await _scheduleKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务'),
        actions: [
          // 视图级操作上收（ui-structure §6.2）：「现在」仅甘特模式显示。
          if (_mode != 0)
            TextButton(
              onPressed: () => _scheduleKey.currentState?.goNow(),
              child: const Text('现在'),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '列表'),
            Tab(text: '日'),
            Tab(text: '月'),
            Tab(text: '年'),
            Tab(text: '年度'),
          ],
        ),
      ),
      floatingActionButton: _listSelecting
          ? null
          : FloatingActionButton(
              tooltip: '新建任务',
              onPressed: _createTask,
              child: const Icon(Icons.add),
            ),
      body: IndexedStack(
        index: _mode == 0 ? 0 : 1,
        children: [
          TaskListView(
            key: _listKey,
            onSelectionChanged: (selecting) =>
                setState(() => _listSelecting = selecting),
          ),
          if (_scheduleBuilt)
            TaskScheduleView(
              key: _scheduleKey,
              granularity: _granularityForMode[_mode] ?? 3,
              onSwitchGranularity: _switchGranularity,
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}
