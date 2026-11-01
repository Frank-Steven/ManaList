import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用当前可见性（U19-C）：决定「自动触发时该不该弹面板」。
///
/// 后台或不在消息页时弹 Modal 面板毫无意义（用户看不到，还会在切回来时突兀出现），
/// 这种情况改用系统通知告知。
///
/// 导航结构调整：底部导航为四主 Tab「库 / 任务 / 助理 / 设置」，设置从
/// 助理页齿轮入口改回底部第 4 个 tab。库页分区顺序「消息 / 笔记 / 文件」，
/// 默认消息分区；任务页视图顺序「列表 / 日 / 月 / 年 / 年度」，默认列表。
/// 位置记忆：库页分区与任务页视图持久化到 shared_preferences，启动时恢复；
/// 主 Tab 位置不记忆（每次回库）。
/// 「消息页可见」仍要求库页停在消息分区。
class AppUiState extends ChangeNotifier {
  AppUiState._();

  static final AppUiState instance = AppUiState._();

  /// HomeShell 里页面顺序：库 / 任务 / 助理 / 设置
  static const int libraryTabIndex = 0;
  static const int tasksTabIndex = 1;
  static const int assistantTabIndex = 2;
  static const int settingsTabIndex = 3;

  /// 底部导航/IndexedStack 的页面总数（下标 0..count-1）。
  static const int tabCount = 4;

  /// 库页（LibraryPage）三分区下标，与 library_page.dart 的 TabController 一致
  /// （顺序：消息 / 笔记 / 文件）。
  static const int librarySectionMessages = 0;
  static const int librarySectionNotes = 1;
  static const int librarySectionFiles = 2;

  /// 位置记忆的持久化键（shared_preferences）。
  static const String librarySectionPrefsKey = 'ui_library_section';
  static const String tasksViewModePrefsKey = 'ui_tasks_view_mode';

  int _tabIndex = 0;
  bool _inForeground = true;

  /// 库页当前分区（其他 tab 时保留上次值，作为下次入库页的初始分区）。
  int _librarySection = librarySectionMessages;

  /// 任务页当前视图：0=列表 1=日 2=月 3=年 4=年度。
  int _tasksViewMode = 0;

  int get tabIndex => _tabIndex;
  bool get inForeground => _inForeground;
  int get librarySection => _librarySection;
  int get tasksViewMode => _tasksViewMode;

  /// 用户此刻正看着消息页（前台 + 库 tab + 消息分区）。
  bool get messagesVisible =>
      _inForeground &&
      _tabIndex == libraryTabIndex &&
      _librarySection == librarySectionMessages;

  /// 启动时恢复位置记忆（库页分区 / 任务页视图）。主 Tab 不记忆，始终回库。
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final section = prefs.getInt(librarySectionPrefsKey);
    if (section != null &&
        section >= librarySectionMessages &&
        section <= librarySectionFiles) {
      _librarySection = section;
    }
    final mode = prefs.getInt(tasksViewModePrefsKey);
    if (mode != null && mode >= 0 && mode <= 4) {
      _tasksViewMode = mode;
    }
  }

  void setTab(int index) {
    if (_tabIndex == index) return;
    _tabIndex = index;
    notifyListeners();
  }

  /// 库页内部分区切换（LibraryPage 的 TabController 双向同步用）。
  void setLibrarySection(int section) {
    if (_librarySection == section) return;
    _librarySection = section;
    _persist(librarySectionPrefsKey, section);
    notifyListeners();
  }

  /// 任务页视图切换（TasksPage 的 TabBar 同步 + 位置记忆）。
  void setTasksViewMode(int mode) {
    if (_tasksViewMode == mode) return;
    _tasksViewMode = mode;
    _persist(tasksViewModePrefsKey, mode);
    notifyListeners();
  }

  /// 别处请求「打开库页并定位到某分区」（如 AI 横幅 → 消息分区）。
  void openLibrary(int section) {
    final changed = _tabIndex != libraryTabIndex || _librarySection != section;
    _tabIndex = libraryTabIndex;
    if (_librarySection != section) {
      _librarySection = section;
      _persist(librarySectionPrefsKey, section);
    }
    if (changed) notifyListeners();
  }

  void setForeground(bool value) {
    if (_inForeground == value) return;
    _inForeground = value;
    notifyListeners();
  }

  /// 位置记忆是体验优化，写入失败（如测试环境无插件实现）不影响功能。
  void _persist(String key, int value) {
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(key, value);
      } catch (e) {
        debugPrint('位置记忆写入失败($key): $e');
      }
    }());
  }
}

/// 消息页角标（U19-B）：底部导航「库」上的未处理条数。
/// 由 MessagesPage.reload 每次刷新后写入，后台也有值（页面常驻）。
class MessageBadges extends ChangeNotifier {
  MessageBadges._();

  static final MessageBadges instance = MessageBadges._();

  int _pending = 0;
  int get pending => _pending;

  void setPending(int value) {
    final v = value < 0 ? 0 : value;
    if (_pending == v) return;
    _pending = v;
    notifyListeners();
  }
}
