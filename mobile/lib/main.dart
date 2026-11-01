import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/app_ui_state.dart';
import 'services/notification_bridge.dart';
import 'services/reminder_service.dart';
import 'ui/assistant/conversations_page.dart';
import 'ui/library/library_page.dart';
import 'ui/settings_page.dart';
import 'ui/tasks/tasks_page.dart';
import 'ui/theme_fader.dart';
import 'services/app_log.dart';

/// 全局主题模式（设置页修改后即时生效）。持久化 key：theme_mode。
final themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode themeModeFromString(String? v) => switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

String themeModeToString(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };

/// 帧耗时埋点（仅 debug，O10 用）：把 ≥32ms 的慢帧打到 logcat，
/// 用来客观比较「切换深浅色」卡不卡（gfxinfo 对 Flutter 自绘无效）。
void _frameWatch() {
  if (!kDebugMode) return;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final ms = t.totalSpan.inMilliseconds;
      if (ms >= 32) {
        debugPrint('[frame] slow ${ms}ms (build ${t.buildDuration.inMilliseconds}ms raster ${t.rasterDuration.inMilliseconds}ms)');
      }
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _frameWatch();

  // 调试期错误落盘：部分设备 logcat 不可读，Flutter/异步错误写入
  // filesDir/debug_errors.log 供 adb pull 排查。
  if (kDebugMode) {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _appendDebugError(
          'FlutterError', details.exceptionAsString(), details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _appendDebugError('PlatformDispatcher', error.toString(), stack);
      return true;
    };
  }

  // 主题模式要在第一帧前就位（否则会先亮一下浅色再跳深色）；这次读取很轻量。
  try {
    final prefs = await SharedPreferences.getInstance();
    themeModeNotifier.value =
        themeModeFromString(prefs.getString('theme_mode'));
    // 位置记忆：库页分区 / 任务页视图启动时恢复（主 Tab 不记忆，每次回库）。
    await AppUiState.instance.restore();
  } catch (e) {
    debugPrint('主题/位置记忆读取失败: $e');
  }

  // 2026-11-01：Flutter 启动页移除，启动画面完全交给原生启动窗
  // （windowBackground 底色+图标，引擎就绪前一直在屏）。重活（提醒初始化/
  // 重排、采集轮询）后台跑，不阻塞 runApp，失败也不阻塞界面。
  runApp(const MsgRepoApp());
  unawaited(_bootstrapColdStart());
}

/// 冷启动的初始化（runApp 之后后台执行，失败也不阻塞界面）。
Future<void> _bootstrapColdStart() async {
  try {
    await ReminderService.instance.init();
    // 进程重启后重排未来提醒（年度任务的逐年重复提醒暂不支持，跳过）
    await ReminderService.instance.rescheduleAll();
  } catch (e, st) {
    // E06：F15 后初始化在首帧后并行执行，失败不再阻塞界面，但绝不能静默 ——
    // 否则本会话所有提醒都会失效，设备侧也无法定因（B04 就卡在这里）。
    // 统一走 ReminderService.recordError（lastError + debugPrint + AppLog 一次），
    // 这里不再额外 AppLog.warn，避免同一条失败在「最近错误」里出现两条。
    ReminderService.instance.noteInitFailure(e, st);
  }
  try {
    NotificationBridge.instance.startPolling();
  } catch (e, st) {
    debugPrint('NotificationBridge 启动失败: $e');
    AppLog.instance.warn('notification.poll', e, st);
  }
}

Future<void> _appendDebugError(
    String kind, String message, StackTrace? stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/debug_errors.log');
    await f.writeAsString(
      '\n=== ${DateTime.now().toIso8601String()} [$kind] ===\n$message\n$stack\n',
      mode: FileMode.append,
    );
  } catch (e, st) {
    AppLog.instance.warn('main.log-file', e, st);
  }
}

/// SnackBar 主题（v2.6）：深色模式不再用 M3 默认的浅反色底——
/// 深色主题用深色 surface + 浅色文字，浅色主题保持反色底。
/// 全局 ThemeData 统一设置，所有 SnackBar（含撤销进度条）自动走此封装。
SnackBarThemeData snackBarThemeFor(ColorScheme cs) {
  final dark = cs.brightness == Brightness.dark;
  return SnackBarThemeData(
    backgroundColor: dark ? cs.surfaceContainerHigh : cs.inverseSurface,
    contentTextStyle:
        TextStyle(color: dark ? cs.onSurface : cs.onInverseSurface),
    actionTextColor: dark ? cs.primary : cs.inversePrimary,
  );
}

/// AppBar 主题（2026-11-01）：取消「内容滚到 AppBar 下方时变色」——
/// M3 默认此时按 scrolledUnderElevation(3) 叠加 surfaceTint；
/// 统一恒为该「滚动后」颜色（滚动前后不再变化）。
AppBarTheme appBarThemeFor(ColorScheme cs) => AppBarTheme(
      scrolledUnderElevation: 0,
      backgroundColor: ElevationOverlay.applySurfaceTint(
          cs.surface, cs.surfaceTint, 3.0),
    );

/// 全局等宽数字（2026-11-01，tnum 字体特性）：日期/时间/计数等数字
/// 逐位等宽，值变化时整串不左右抖动（倒计时、时间戳、进度数字尤其明显）。
/// 作用在 TextTheme 层，各页面无需逐处设置；默认字体（Roboto）支持 tnum。
TextTheme _tabularTextTheme(TextTheme base) {
  const features = [FontFeature.tabularFigures()];
  TextStyle? t(TextStyle? s) => s?.copyWith(fontFeatures: features);
  return TextTheme(
    displayLarge: t(base.displayLarge),
    displayMedium: t(base.displayMedium),
    displaySmall: t(base.displaySmall),
    headlineLarge: t(base.headlineLarge),
    headlineMedium: t(base.headlineMedium),
    headlineSmall: t(base.headlineSmall),
    titleLarge: t(base.titleLarge),
    titleMedium: t(base.titleMedium),
    titleSmall: t(base.titleSmall),
    bodyLarge: t(base.bodyLarge),
    bodyMedium: t(base.bodyMedium),
    bodySmall: t(base.bodySmall),
    labelLarge: t(base.labelLarge),
    labelMedium: t(base.labelMedium),
    labelSmall: t(base.labelSmall),
  );
}

ThemeData _withTabularFigures(ThemeData theme) => theme.copyWith(
      textTheme: _tabularTextTheme(theme.textTheme),
      primaryTextTheme: _tabularTextTheme(theme.primaryTextTheme),
    );

// 主题只算一次（O10）：`ColorScheme.fromSeed` 每次构建都跑一遍 HCT 换算，
// 切换深浅色时它被重复执行两遍，是主题切换卡顿的固定开销之一。
final ColorScheme _lightScheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
final ColorScheme _darkScheme =
    ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark);
final ThemeData _lightTheme = _withTabularFigures(ThemeData(
  useMaterial3: true,
  colorScheme: _lightScheme,
  snackBarTheme: snackBarThemeFor(_lightScheme),
  appBarTheme: appBarThemeFor(_lightScheme),
));
final ThemeData _darkTheme = _withTabularFigures(ThemeData(
  useMaterial3: true,
  colorScheme: _darkScheme,
  snackBarTheme: snackBarThemeFor(_darkScheme),
  appBarTheme: appBarThemeFor(_darkScheme),
));

class MsgRepoApp extends StatelessWidget {
  const MsgRepoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'ManaList',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: mode,
          // O10：过渡时长从默认 200ms 收到 160ms。主题切换期间整棵树逐帧重建，
          // 缩短时长能减少「卡一下」的总帧数，观感靠曲线保住平滑。
            // O10 第二方案：主题切换**不做逐帧插值**（那会让整棵树每帧重建，实测单帧 build 200~960ms），
            // 改为「抓快照 → 立刻换主题 → 快照淡出」，见 ui/theme_fader.dart。
            themeAnimationDuration: Duration.zero,
            builder: (context, child) =>
                ThemeFader(child: child ?? const SizedBox.shrink()),
            home: const HomeShell(),
        );
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // F08：别处（消息详情「关联待办」等）通过 AppUiState.setTab 请求切页时，
    // HomeShell 是唯一决定显示哪个页的地方 —— 订阅回来，把请求落到 _index。
    AppUiState.instance.addListener(_syncTab);
    AppUiState.instance.setTab(_index);
    // 冷启动时可能已在后台（如被通知拉起），用真实生命周期初始化
    final lc = WidgetsBinding.instance.lifecycleState;
    AppUiState.instance
        .setForeground(lc == null || lc == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    AppUiState.instance.removeListener(_syncTab);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 把 AppUiState 里的切页请求同步成真正的页面切换（F08）。
  ///
  /// 以前 _index 只被本地写、AppUiState 只被写不被读，于是
  /// message_detail_sheet 的 setTab（跳「待办」，现为「任务」tab）没有任何效果。
  void _syncTab() {
    if (!mounted) return;
    final next =
        AppUiState.instance.tabIndex.clamp(0, AppUiState.tabCount - 1);
    if (next == _index) return; // 本地切换已同步过，避免重复 setState/重复 reload
    setState(() {
      _index = next;
      _builtTabs.add(next); // O10 懒构建：外部切页也要真正创建该页
    });
    _reloadTab(next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // U19-C：只有真正离开（pause/hidden/detach）才算后台；
    // inactive 可能只是分屏/失焦/系统弹窗，不该因此改成发通知。
    final background = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    AppUiState.instance.setForeground(!background);
  }

  int _index = 0;

  // IndexedStack 保活页面不会随切页重跑 initState，切入时用 GlobalKey 主动刷新
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _tasksKey = GlobalKey<TasksPageState>();
  final _assistantKey = GlobalKey<ConversationsPageState>();

  // 设置页 State 为私有，无法 GlobalKey 调 reload；每次切入换 key 重建，
  // 让 initState 的 _load 重跑（权限/过滤配置等保持新鲜）。
  Key _settingsKey = UniqueKey();

  // O10：页面懒构建。原来所有页面在 initState 就全部创建，IndexedStack 又会构建全部子页 ——
  // 任何主题切换都要把这些树重新 build 一遍（真机实测单帧 build 达 924ms）。
  // 现在只构建「用户访问过」的页面，没访问过的放占位，切过去时再创建（GlobalKey 保状态）。
  final Set<int> _builtTabs = {0};

  Widget _pageAt(int i) {
    if (!_builtTabs.contains(i)) return const SizedBox.shrink();
    return switch (i) {
      AppUiState.libraryTabIndex => LibraryPage(key: _libraryKey),
      AppUiState.tasksTabIndex => TasksPage(key: _tasksKey),
      AppUiState.assistantTabIndex => ConversationsPage(key: _assistantKey),
      _ => SettingsPage(key: _settingsKey),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // O10：RepaintBoundary 把页面栈的重绘与导航栏隔开，
          // 主题过渡时不必带着整屏一起重绘。
          Expanded(
            child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (var i = 0; i < AppUiState.tabCount; i++)
                      _TabVisibility(visible: i == _index, child: _pageAt(i)),
                  ],
                ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: MessageBadges.instance,
        builder: (context, _) => _buildNavBar(),
      ),
    );
  }

  /// 切到某个 tab 后按需刷新该页（页面常驻保活，不会重跑 initState）。
  void _reloadTab(int i) {
    switch (i) {
      case AppUiState.libraryTabIndex:
        _libraryKey.currentState?.reload();
      case AppUiState.tasksTabIndex:
        _tasksKey.currentState?.reload();
      case AppUiState.assistantTabIndex:
        _assistantKey.currentState?.reload();
      case AppUiState.settingsTabIndex:
        // 换 key 强制重建，等效于 reload（在本次 setState 的下一帧生效）。
        _settingsKey = UniqueKey();
    }
  }

  /// U19-B：底部导航；「库」带消息未处理数角标（页面常驻，后台也会刷新）
  Widget _buildNavBar() {
    final pending = MessageBadges.instance.pending;
    return NavigationBar(
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: _index,
      onDestinationSelected: (i) {
        setState(() {
          _index = i;
          _builtTabs.add(i); // 首次访问时才真正创建该页
        });
        AppUiState.instance.setTab(i);
        _reloadTab(i);
      },
      destinations: [
        NavigationDestination(
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text(pending > 99 ? '99+' : '$pending'),
              child: const Icon(Icons.inventory_2_outlined),
            ),
            label: '库'),
        const NavigationDestination(
            icon: Icon(Icons.check_circle_outline), label: '任务'),
        const NavigationDestination(
            icon: Icon(Icons.smart_toy_outlined), label: '助理'),
        const NavigationDestination(
            icon: Icon(Icons.settings_outlined), label: '设置'),
      ],
    );
  }
}

/// 主 Tab 切换过渡（2026-11-01）：切入页淡入 + 轻微右→左滑入，
/// 切出页同步淡出（交叉淡化）；所有已构建页面常驻（与 IndexedStack
/// 同等的保活语义），隐藏页移出绘制/命中/语义。
class _TabVisibility extends StatefulWidget {
  const _TabVisibility({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_TabVisibility> createState() => _TabVisibilityState();
}

class _TabVisibilityState extends State<_TabVisibility>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 250);

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _duration,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(_TabVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    // 不带 from：快速连点 Tab 时从当前值继续，不跳变
    if (widget.visible) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final v = Curves.easeOut.transform(_ctrl.value);
        return Visibility(
          visible: v > 0,
          maintainState: true,
          maintainSize: true,
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset((1 - v) * 12, 0),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
