import 'package:flutter/material.dart';

import '../services/archive_export_service.dart';

/// 关于页：应用名 / 版本 / 定位简介 / 桌面网关 LinkModel 说明。
/// 版本号复用 [ArchiveExportService.appVersion]（与 pubspec version 同源维护）。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const appName = 'ManaList';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/splash/icon.png',
                width: 72,
                height: 72,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(appName,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text('版本 ${ArchiveExportService.appVersion}',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ),
          const SizedBox(height: 32),
          Text('定位', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'AI 驱动的待办日程管理：库 · 任务 · 助理。采集手机通知与手动消息，'
            '由 AI 整理为日程、待办与笔记，本地存储与提醒。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Text('桌面网关', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'LinkModel 是电脑端本地 AI 统一接口（AI 网关）：状态栏托盘应用 + '
            '内嵌 HTTP 服务，提供模型列表与统一对话接口，经 adb 通道为本应用'
            '提供 AI 能力。LinkModel 只做模型路由与协议透传，不保存业务数据。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
