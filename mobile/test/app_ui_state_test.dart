import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// U19-B/C 回归：可见性判定 + 角标计数。
/// 后台或不在消息页时不应弹 AI 面板（改发系统通知）。
/// 导航结构调整：库页三分区顺序「消息 / 笔记 / 文件」、默认消息分区；
/// 库分区与任务视图经 shared_preferences 记忆（ui_library_section /
/// ui_tasks_view_mode），主 Tab 不记忆。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 单例跨用例共享，先复位，避免污染其它测试文件
    SharedPreferences.setMockInitialValues({});
    AppUiState.instance.setTab(0);
    AppUiState.instance.setLibrarySection(AppUiState.librarySectionMessages);
    AppUiState.instance.setTasksViewMode(0);
    AppUiState.instance.setForeground(true);
    MessageBadges.instance.setPending(0);
  });

  test('只有「前台 + 库页的消息分区」才算消息页可见', () {
    final s = AppUiState.instance;
    s.openLibrary(AppUiState.librarySectionMessages);
    s.setForeground(true);
    expect(s.messagesVisible, isTrue, reason: '前台 + 库页消息分区');

    s.setForeground(false);
    expect(s.messagesVisible, isFalse, reason: '切到后台就不算可见');

    s.setForeground(true);
    s.setTab(AppUiState.tasksTabIndex);
    expect(s.messagesVisible, isFalse, reason: '前台但在日程页也不算');

    s.openLibrary(AppUiState.librarySectionMessages);
    expect(s.messagesVisible, isTrue);

    s.setLibrarySection(AppUiState.librarySectionFiles);
    expect(s.messagesVisible, isFalse, reason: '库页停在文件分区也不算');

    s.setLibrarySection(AppUiState.librarySectionMessages);
    expect(s.messagesVisible, isTrue);
  });

  test('openLibrary 同时切 tab 与分区；setTab 不丢分区记忆', () {
    final s = AppUiState.instance;
    s.openLibrary(AppUiState.librarySectionFiles);
    expect(s.tabIndex, AppUiState.libraryTabIndex);
    expect(s.librarySection, AppUiState.librarySectionFiles);

    s.setTab(AppUiState.tasksTabIndex);
    expect(s.librarySection, AppUiState.librarySectionFiles,
        reason: '切走再切回时应保留上次分区');

    s.setTab(AppUiState.libraryTabIndex);
    expect(s.librarySection, AppUiState.librarySectionFiles);
  });

  test('默认：库页消息分区、任务页列表视图、主 Tab 回库', () {
    expect(AppUiState.librarySectionMessages, 0);
    expect(AppUiState.librarySectionNotes, 1);
    expect(AppUiState.librarySectionFiles, 2);
    expect(AppUiState.tabCount, 4);
    expect(AppUiState.settingsTabIndex, 3);
  });

  test('位置记忆：库分区与任务视图写入 prefs，restore 启动时恢复', () async {
    final s = AppUiState.instance;
    SharedPreferences.setMockInitialValues({
      AppUiState.librarySectionPrefsKey: AppUiState.librarySectionFiles,
      AppUiState.tasksViewModePrefsKey: 4,
    });
    await s.restore();
    expect(s.librarySection, AppUiState.librarySectionFiles);
    expect(s.tasksViewMode, 4);
    expect(s.tabIndex, AppUiState.libraryTabIndex, reason: '主 Tab 不记忆，回库');

    // setter 持久化：切分区/视图后 prefs 同步更新
    s.setLibrarySection(AppUiState.librarySectionNotes);
    s.setTasksViewMode(2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(AppUiState.librarySectionPrefsKey),
        AppUiState.librarySectionNotes);
    expect(prefs.getInt(AppUiState.tasksViewModePrefsKey), 2);

    // 越界值不恢复（防御旧版本/手改数据）
    SharedPreferences.setMockInitialValues({
      AppUiState.librarySectionPrefsKey: 9,
      AppUiState.tasksViewModePrefsKey: -1,
    });
    s.setLibrarySection(AppUiState.librarySectionMessages);
    s.setTasksViewMode(0);
    await s.restore();
    expect(s.librarySection, AppUiState.librarySectionMessages);
    expect(s.tasksViewMode, 0);
  });

  test('角标：负数归零，同值不重复通知', () {
    final b = MessageBadges.instance;
    var notified = 0;
    void listener() => notified++;
    b.addListener(listener);
    addTearDown(() => b.removeListener(listener));

    b.setPending(7);
    expect(b.pending, 7);
    final afterFirst = notified;
    b.setPending(7);
    expect(notified, afterFirst, reason: '同值不该触发重建');

    b.setPending(-3);
    expect(b.pending, 0);
  });
}
