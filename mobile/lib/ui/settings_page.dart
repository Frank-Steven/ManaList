import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_fader.dart';
import '../main.dart' show themeModeNotifier, themeModeFromString;
import 'about_page.dart';
import 'shared/app_icon.dart';
import 'shared/segmented_selector.dart';
import '../services/app_filter_service.dart';
import '../services/archive_export_service.dart';
import '../services/archive_import_service.dart';
import '../services/notification_bridge.dart';
import '../services/reminder_service.dart';
import '../../services/app_log.dart';

/// B03：切到「仅指定应用」前是否需要先让用户选应用。
///
/// 空 allowlist 在数据层就等于「一条通知都不采集」（[AppFilterConfig.allows] 的既定契约，
/// 不在这里改），而切模式只是一键操作，用户很容易在没加任何应用时就切过去。
/// 所以把「先加应用、再加模式」的顺序提到 UI 层防呆。
bool filterNeedsAppSelection(String targetMode, List<String> currentPackages) =>
    targetMode == AppFilterConfig.modeAllowlist && currentPackages.isEmpty;

/// B03：把应用选择结果合进「仅指定应用」配置。
///
/// [picked] 为 null（用户按返回取消）或空集合（一个都没勾）时返回 null，
/// 调用方据此保持原模式不变，避免静默切成「全屏蔽」。
AppFilterConfig? filterConfigAfterSelection({
  required List<String> currentPackages,
  required Set<String>? picked,
}) {
  if (picked == null || picked.isEmpty) return null;
  final merged = <String>{...currentPackages, ...picked};
  return AppFilterConfig(
      mode: AppFilterConfig.modeAllowlist, packages: merged.toList());
}

/// 设置页（design-v3 §3.5）：外观 / 数据 / 采集过滤 / 后台保活。
/// 「AI 接口配置 / 配对 / 端点管理」段已迁入助理页（model_picker）；
/// v2 的「自定义提示词」「自动处理」段随批处理管线删除（阶段 7），
/// 批量评估由助理工具 inbox.triage 承担。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _themeMode = 'system';

  bool _listenerEnabled = false;
  bool _exporting = false;
  bool _importing = false;
  bool _batteryOptimized = true; // true = 已加入白名单（不需要再优化）
  bool _exactAlarms = true; // 精确闹钟权限（Android 12+ 可能需要手动开启）
  AppFilterConfig _filterConfig = const AppFilterConfig();
  Map<String, String?> _knownAppNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final listenerEnabled =
        await NotificationBridge.instance.isListenerEnabled();
    final batteryOptimized =
        await NotificationBridge.instance.isIgnoringBatteryOptimizations();
    final exactAlarms = await ReminderService.instance.refreshExactAlarms();
    final filterConfig = await AppFilterService.instance.load();
    final seenApps = await AppFilterService.instance.getSeenApps();
    if (!mounted) return;
    setState(() {
      _themeMode = prefs.getString('theme_mode') ?? 'system';
      _listenerEnabled = listenerEnabled;
      _batteryOptimized = batteryOptimized;
      _exactAlarms = exactAlarms;
      _filterConfig = filterConfig;
      _knownAppNames = {for (final a in seenApps) a.packageName: a.appName};
    });
  }

  void _toast(String text) {
    if (!mounted) return; // P3-5：await 之后调用时页面可能已销毁
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(text), duration: const Duration(seconds: 2)));
  }

  // ---- 外观 ----

  Future<void> _setThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode);
    // O10：走「快照渐变」切换，避免整棵树逐帧重建造成的卡顿
    await ThemeFader.switchTo(
      () => themeModeNotifier.value = themeModeFromString(mode),
    );
    if (mounted) setState(() => _themeMode = mode);
  }

  // ---- 采集过滤 ----

  Future<void> _saveFilter(AppFilterConfig config) async {
    await AppFilterService.instance.save(config);
    if (mounted) setState(() => _filterConfig = config);
  }

  String _appDisplayName(String packageName) {
    final name = _knownAppNames[packageName];
    return (name != null && name.isNotEmpty) ? name : packageName;
  }

  /// 打开应用选择页，返回用户勾选的包名集合；用户取消（返回键）时为 null。
  Future<Set<String>?> _pickFilteredApps() async {
    // v2.4：应用选择页以 PackageManager 全量可启动应用为主，
    // 补充"已见但已卸载/无启动器入口"的历史应用
    final results = await Future.wait([
      AppFilterService.instance.getInstalledApps(),
      AppFilterService.instance.getSeenApps(),
    ]);
    final installed = results[0];
    final seen = results[1];
    final installedPkgs = {for (final a in installed) a.packageName};
    final extra = seen.where((a) => !installedPkgs.contains(a.packageName));
    final apps = [...installed, ...extra];
    if (!mounted) return null;
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => _AppPickerPage(
          title: _filterConfig.isBlacklist ? '选择要屏蔽的应用' : '选择要采集的应用',
          apps: apps,
          initiallySelected: _filterConfig.packages.toSet(),
        ),
      ),
    );
    if (selected == null || !mounted) return selected;
    final names = Map<String, String?>.of(_knownAppNames);
    for (final a in apps) {
      names[a.packageName] = a.appName;
    }
    setState(() => _knownAppNames = names);
    return selected;
  }

  Future<void> _addFilteredApps() async {
    final selected = await _pickFilteredApps();
    if (selected == null) return;
    final packages = _filterConfig.packages.toSet()..addAll(selected);
    await _saveFilter(_filterConfig.copyWith(packages: packages.toList()));
  }

  /// B03：切模式时对「仅指定应用 + 空名单」防呆 —— 先让用户选应用；
  /// 取消或一个都没勾则**保持原模式**，只给一条提示。
  Future<void> _onFilterModeChanged(String v) async {
    if (!filterNeedsAppSelection(v, _filterConfig.packages)) {
      await _saveFilter(_filterConfig.copyWith(mode: v));
      return;
    }
    final selected = await _pickFilteredApps();
    if (!mounted) return;
    final next = filterConfigAfterSelection(
      currentPackages: _filterConfig.packages,
      picked: selected,
    );
    if (next == null) {
      _toast('未添加应用，仍收集全部应用的通知');
      return;
    }
    await _saveFilter(next);
  }

  // ---- 数据（v3 存档导出/导入，design-v3-details §5）----

  Future<void> _exportArchive() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final result = await ArchiveExportService.instance.exportArchive();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导出完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('任务 ${result.tasks} 条 · 消息 ${result.messages} 条 · '
                  '笔记 ${result.notes} 篇 · 文件 ${result.files} 个 · '
                  '锚点 ${result.anchors} 条'
                  '${result.skippedFiles > 0 ? '\n${result.skippedFiles} 个附件文件已丢失，未打包' : ''}'),
              const SizedBox(height: 12),
              Text('存档位置：',
                  style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              SelectableText(result.path,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导入存档（design-v3-details §5.3）：选 zip → 格式校验 → 空库守卫 →
  /// 单事务入库 → 展示统计与一致性警告。
  Future<void> _importArchive() async {
    if (_importing) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _importing = true);
    try {
      final result =
          await ArchiveImportService.instance.importArchive(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('任务 ${result.tasks} 条 · 消息 ${result.messages} 条 · '
                  '笔记 ${result.notes} 篇 · 文件 ${result.files} 个 · '
                  '锚点 ${result.anchors} 条'),
              if (result.warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('警告（${result.warnings.length} 条，不阻断导入）：',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                for (final w in result.warnings)
                  Text('· $w', style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on ArchiveImportException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ---- 后台保活（v2.6）----

  Future<void> _requestBatteryWhitelist() async {
    final opened =
        await NotificationBridge.instance.requestIgnoreBatteryOptimizations();
    if (!opened && mounted) _toast('无法打开电池优化设置');
    // 系统设置返回后状态可能已变，延迟刷新
    await Future.delayed(const Duration(seconds: 1));
    _load();
  }

  /// 请求精确闹钟权限（Android 12+ 可能需要用户手动开启）。
  Future<void> _requestExactAlarms() async {
    final ok = await ReminderService.instance.requestExactAlarms();
    if (!mounted) return;
    setState(() => _exactAlarms = ok);
    _toast(ok ? '已允许精确提醒' : '未获得精确闹钟权限：提醒仍会触发，但可能延迟数分钟');
  }

  /// 展示最近被记录的异常（P2-6）：把以前静默吞掉的失败变成可读列表。
  Future<void> _showRecentErrors() async {
    final entries = AppLog.instance.entries;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('最近错误（${entries.length} 类）'),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? const Text('暂无记录。')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SelectableText(e.oneLine,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              AppLog.instance.clear();
              Navigator.of(ctx).pop();
              setState(() {});
            },
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAutoStartSettings() async {
    final opened = await NotificationBridge.instance.openAutoStartSettings();
    if (opened || !mounted) return;
    // 无已知厂商组件可跳：图文引导 + 应用详情页兜底入口
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动开启保活权限'),
        content: const SingleChildScrollView(
          child: Text('未能直接跳转自启动设置，请手动操作：\n\n'
              'vivo / iQOO：\n'
              'i 管家 → 应用管理 → 权限管理 → 自启动 → 允许 ManaList；\n'
              '设置 → 电池 → 后台耗电管理 → ManaList → 允许后台高耗电。\n\n'
              '其他机型：\n'
              '系统设置 → 应用管理 → ManaList → 允许自启动 / 后台运行 / '
              '电池不优化（名称因厂商而异）。'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              NotificationBridge.instance.openAppDetailsSettings();
            },
            child: const Text('打开应用详情'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ---- UI ----

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('外观', [
            SegmentedSelector<String>(
              values: const ['system', 'light', 'dark'],
              labels: const ['跟随系统', '浅色', '深色'],
              height: 40,
              selected: _themeMode,
              onChanged: _setThemeMode,
            ),
          ]),
          const Divider(height: 32),
          _section('数据', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.archive_outlined, color: cs.onSurfaceVariant),
              title: const Text('导出存档'),
              subtitle: Text(
                '把全部消息、任务、笔记与附件打包为一个 zip（v3 存档格式）',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
              onTap: _exporting ? null : _exportArchive,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.unarchive_outlined, color: cs.onSurfaceVariant),
              title: const Text('导入存档'),
              subtitle: Text(
                '从 zip 存档还原全部数据（仅空库可导入，不合并）',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
              onTap: _importing ? null : _importArchive,
            ),
          ]),
          const Divider(height: 32),
          _section('采集过滤', [
            Row(
              children: [
                Icon(
                  _listenerEnabled
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  color: _listenerEnabled ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_listenerEnabled
                      ? '通知监听已授权'
                      : '通知监听未授权，无法自动采集通知'),
                ),
                if (!_listenerEnabled)
                  TextButton(
                    onPressed: () async {
                      await NotificationBridge.instance.openListenerSettings();
                      await Future.delayed(const Duration(seconds: 1));
                      _load();
                    },
                    child: const Text('去授权'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedSelector<String>(
              values: const [
                AppFilterConfig.modeAll,
                AppFilterConfig.modeAllowlist,
                AppFilterConfig.modeBlacklist,
              ],
              labels: const ['全部应用', '仅指定应用', '屏蔽指定应用'],
              height: 40,
              selected: _filterConfig.mode,
              // B03：切到「仅指定应用」且名单为空时，先弹应用选择器，
              // 没选就保持原模式（否则空 allowlist 会静默切断全部采集）
              onChanged: _onFilterModeChanged,
            ),
            if (_filterConfig.isAllowlist || _filterConfig.isBlacklist) ...[
              const SizedBox(height: 12),
              if (_filterConfig.isAllowlist && _filterConfig.packages.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_outlined,
                              color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '当前不会收集任何应用的通知，请添加应用或切换为全部应用',
                              style: TextStyle(color: cs.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                      // B03：给一条一键退路，避免用户卡在「一条都收不到」里
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: cs.onErrorContainer,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 36),
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => _saveFilter(_filterConfig
                              .copyWith(mode: AppFilterConfig.modeAll)),
                          child: const Text('切换为全部应用'),
                        ),
                      ),
                    ],
                  ),
                ),
              // 统一 Chip 行（设计 §10.2）：横向滚动，添加/删除都在行内
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final pkg in _filterConfig.packages)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InputChip(
                          avatar: AppIcon(
                              packageName: pkg,
                              appName: _knownAppNames[pkg]),
                          label: Text(_appDisplayName(pkg)),
                          onDeleted: () {
                            final packages = _filterConfig.packages.toList()
                              ..remove(pkg);
                            _saveFilter(
                                _filterConfig.copyWith(packages: packages));
                          },
                        ),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: Text(_filterConfig.isBlacklist
                          ? '添加屏蔽应用'
                          : '添加应用'),
                      onPressed: _addFilteredApps,
                    ),
                  ],
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('收集所有应用的通知（手动添加的消息不受此设置影响）',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ),
          ]),
          const Divider(height: 32),
          _section('后台保活', [
            Row(
              children: [
                Icon(
                  _batteryOptimized
                      ? Icons.battery_saver_outlined
                      : Icons.battery_alert_outlined,
                  color: _batteryOptimized ? cs.primary : cs.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_batteryOptimized
                      ? '已加入电池优化白名单'
                      : '未加入电池优化白名单，系统可能随时停止消息监听'),
                ),
                if (!_batteryOptimized)
                  TextButton(
                    onPressed: _requestBatteryWhitelist,
                    child: const Text('去设置'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _exactAlarms ? Icons.alarm_on_outlined : Icons.alarm_off_outlined,
                  color: _exactAlarms ? cs.primary : cs.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_exactAlarms
                      ? '任务提醒：精确闹钟已允许'
                      : '任务提醒：未允许精确闹钟，提醒可能延迟数分钟'),
                ),
                if (!_exactAlarms)
                  TextButton(
                    onPressed: _requestExactAlarms,
                    child: const Text('去设置'),
                  ),
              ],
            ),
            // E06（2026-10-24）：提醒初始化/调度失败必须可见 —— 无错误时不显示，不增加干扰。
            if (ReminderService.instance.lastError != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: cs.error),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '任务提醒异常：${ReminderService.instance.lastError}',
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.rocket_launch_outlined, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                const Expanded(child: Text('自启动 / 后台运行（国产 ROM 必开）')),
                TextButton(
                  onPressed: _openAutoStartSettings,
                  child: const Text('去设置'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '消息监听经常停止时：把本应用加入电池优化白名单，并在系统设置中'
                '允许自启动与后台运行（vivo：i 管家 → 自启动；电池 → 后台耗电'
                '管理 → 允许后台高耗电）。',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            // P2-6：异常不再被静默吞掉，这里给出统一查看入口
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                AppLog.instance.count == 0
                    ? Icons.check_circle_outline
                    : Icons.bug_report_outlined,
                color: AppLog.instance.count == 0 ? cs.primary : cs.error,
              ),
              title: const Text('最近错误'),
              subtitle: Text(
                AppLog.instance.count == 0 ? '暂无可显示的异常' : '${AppLog.instance.count} 类，点击查看',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showRecentErrors,
            ),
          ]),
          const Divider(height: 32),
          _section('关于', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.info_outline, color: cs.onSurfaceVariant),
              title: const Text('关于 ${AboutPage.appName}'),
              subtitle: Text(
                '版本 ${ArchiveExportService.appVersion}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutPage()),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// 应用选择页（v2.4 改为 PackageManager 全量列表 + 已见历史应用），
/// 支持搜索、图标展示，并可手动输入包名。
class _AppPickerPage extends StatefulWidget {
  final String title;
  final List<SeenApp> apps;
  final Set<String> initiallySelected;

  const _AppPickerPage({
    required this.title,
    required this.apps,
    required this.initiallySelected,
  });

  @override
  State<_AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<_AppPickerPage> {
  final _searchController = TextEditingController();
  late final Set<String> _selected = Set.of(widget.initiallySelected);
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addManualPackage() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动输入包名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '包名',
            hintText: '如 com.tencent.mm',
            helperText: '无启动器入口的应用不出现在列表中，可在此手动添加',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) {
      setState(() => _selected.add(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final visible = widget.apps
        .where((a) =>
            query.isEmpty ||
            a.displayName.toLowerCase().contains(query) ||
            a.packageName.toLowerCase().contains(query))
        .toList();
    // 已选但不在应用列表里的（手动输入的包名）也要显示，便于取消勾选
    final listedPackages = widget.apps.map((a) => a.packageName).toSet();
    final manualOnly =
        _selected.where((p) => !listedPackages.contains(p)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('完成'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索应用名或包名',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.keyboard),
                  tooltip: '手动输入包名',
                  onPressed: _addManualPackage,
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final pkg in manualOnly)
                  CheckboxListTile(
                    value: true,
                    onChanged: (_) =>
                        setState(() => _selected.remove(pkg)),
                    title: Text(pkg),
                    subtitle: const Text('手动添加'),
                  ),
                for (final app in visible)
                  CheckboxListTile(
                    value: _selected.contains(app.packageName),
                    onChanged: (v) => setState(() => v == true
                        ? _selected.add(app.packageName)
                        : _selected.remove(app.packageName)),
                    secondary: AppIcon(
                        packageName: app.packageName,
                        appName: app.appName,
                        size: 28),
                    title: Text(app.displayName),
                    subtitle: Text(app.packageName),
                  ),
                if (visible.isEmpty && manualOnly.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: Text('无匹配应用；'
                            '也可点搜索框右侧按钮手动输入包名')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
