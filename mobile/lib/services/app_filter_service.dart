import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_log.dart';

/// 应用采集过滤配置（手机端本地配置，不属于 shared/schemas）。
///
/// 与 Kotlin 侧共享的存储契约：
/// - shared_preferences key：`app_filter_config`（插件在 Android 上写入名为
///   `FlutterSharedPreferences` 的 SharedPreferences 文件，实际 key 带前缀
///   `flutter.app_filter_config`，Kotlin 端按此读取）；
/// - 值为 JSON 字符串：`{"mode": "all" | "allowlist" | "blacklist", "packages": ["com.x.y", ...]}`；
/// - mode=all 收集全部（默认）；mode=allowlist 时只收集 packages 中的应用，
///   空列表 = 什么都不收集；mode=blacklist 时屏蔽 packages 中的应用、其余全收。
///   手动添加的消息（packageName="manual"）不受影响。
class AppFilterConfig {
  static const modeAll = 'all';
  static const modeAllowlist = 'allowlist';
  static const modeBlacklist = 'blacklist';

  final String mode;
  final List<String> packages;

  const AppFilterConfig({this.mode = modeAll, this.packages = const []});

  bool get isAllowlist => mode == modeAllowlist;
  bool get isBlacklist => mode == modeBlacklist;

  /// 采集放行判定（镜像 Kotlin NotificationCaptureService.isAllowed 的语义）：
  /// allowlist 只放行名单内；blacklist 拦截名单内；其余（all/未知）全放行。
  bool allows(String packageName) => switch (mode) {
        modeAllowlist => packages.contains(packageName),
        modeBlacklist => !packages.contains(packageName),
        _ => true,
      };

  factory AppFilterConfig.fromJson(Map<String, dynamic> json) =>
      AppFilterConfig(
        mode: json['mode'] as String? ?? modeAll,
        packages:
            (json['packages'] as List? ?? []).map((e) => e.toString()).toList(),
      );

  Map<String, dynamic> toJson() => {'mode': mode, 'packages': packages};

  AppFilterConfig copyWith({String? mode, List<String>? packages}) =>
      AppFilterConfig(
        mode: mode ?? this.mode,
        packages: packages ?? this.packages,
      );
}

/// 发过通知的应用记录（Kotlin 端写入 filesDir/seen_apps.json）。
class SeenApp {
  final String packageName;
  final String? appName;
  final int lastSeenAt;

  const SeenApp({
    required this.packageName,
    this.appName,
    required this.lastSeenAt,
  });

  String get displayName =>
      (appName != null && appName!.isNotEmpty) ? appName! : packageName;
}

class AppFilterService {
  AppFilterService._();

  static final AppFilterService instance = AppFilterService._();

  static const _prefsKey = 'app_filter_config';
  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  Future<AppFilterConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsKey);
    if (json == null) return const AppFilterConfig();
    try {
      return AppFilterConfig.fromJson(
          (jsonDecode(json) as Map).cast<String, dynamic>());
    } catch (e, st) {
      AppLog.instance.warn('filter.parse-config', e, st);
      return const AppFilterConfig();
    }
  }

  Future<void> save(AppFilterConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
  }

  /// 经 MethodChannel 读取 Kotlin 侧维护的 seen_apps.json，
  /// 按 lastSeenAt 降序返回。
  Future<List<SeenApp>> getSeenApps() async {
    try {
      final json = await _channel.invokeMethod<String>('getSeenApps');
      if (json == null || json.isEmpty) return [];
      final root = (jsonDecode(json) as Map).cast<String, dynamic>();
      final apps = <SeenApp>[];
      for (final entry in root.entries) {
        final v = (entry.value as Map).cast<String, dynamic>();
        apps.add(SeenApp(
          packageName: v['packageName'] as String? ?? entry.key,
          appName: v['appName'] as String?,
          lastSeenAt: (v['lastSeenAt'] as num?)?.toInt() ?? 0,
        ));
      }
      apps.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
      return apps;
    } catch (e, st) {
      AppLog.instance.warn('filter.read-seen', e, st);
      return [];
    }
  }

  /// 已安装的可启动应用（PackageManager 全量，v2.4 设置页应用筛选用），
  /// 按应用名排序。
  Future<List<SeenApp>> getInstalledApps() async {
    try {
      final json = await _channel.invokeMethod<String>('getInstalledApps');
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List;
      return [
        for (final e in list)
          SeenApp(
            packageName:
                (e as Map)['packageName']?.toString() ?? '',
            appName: e['appName']?.toString(),
            lastSeenAt: 0,
          ),
      ]..sort((a, b) => a.displayName
          .toLowerCase()
          .compareTo(b.displayName.toLowerCase()));
    } catch (e, st) {
      AppLog.instance.warn('filter.read-installed', e, st);
      return [];
    }
  }
}
