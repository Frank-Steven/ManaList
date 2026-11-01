import 'dart:io';

import 'package:flutter/services.dart';

/// 系统能力（F09 打开链接 / F10 导出附件）。
///
/// 走 `MainActivity` 已有的 MethodChannel（`CHANNEL`），不引入 url_launcher / open_file 依赖：
/// - `openUrl`：ACTION_VIEW 打开 http(s) 链接；没有可用应用时返回 false（不抛异常）。
/// - `exportToDownloads`：把应用私有目录里的文件导出到系统「下载」目录（MediaStore，
///   Android 10+ 无需存储权限），返回「下载/<文件名>」这样的可见描述。
class SystemIntent {
  SystemIntent._();

  /// 与 NotificationBridge 共用同一个通道名（MainActivity.CHANNEL）。
  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  /// 打开链接。成功 true；失败（无浏览器/非法 URL）false。
  static Future<bool> openUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openUrl', {'url': u});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 导出一个本地文件到系统下载目录，返回可见位置描述（失败抛异常由调用方提示）。
  static Future<String> exportToDownloads(String path,
      {required String name, String mime = 'application/octet-stream'}) async {
    final r = await _channel.invokeMethod<String>('exportToDownloads', {
      'path': path,
      'name': name,
      'mime': mime,
    });
    return r ?? name;
  }

  /// 常见扩展名 → MIME（导出时给系统一个像样的类型，避免一律 octet-stream）。
  static String mimeOf(String? fileName) {
    final ext = (fileName ?? '').split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt' => 'text/plain',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'zip' => 'application/zip',
      'apk' => 'application/vnd.android.package-archive',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      _ => File(fileName ?? '').path.isEmpty ? 'application/octet-stream' : 'application/octet-stream',
    };
  }
}
