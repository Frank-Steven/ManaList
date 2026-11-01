import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// B04 回归守卫（2026-10-24）：flutter_local_notifications 从 16 版起**不再**在自己的
/// manifest 里声明广播接收器，改为要求 App 自己声明（插件 17.2.4 README:252-263）。
///
/// 漏声明的后果极其隐蔽：任务提醒照常「排上」（dumpsys alarm 有条目）、到点
/// AlarmManager 照常触发，但广播的目标组件不存在 → 通知 0 条；而且应用进程根本
/// 不会被拉起，所以 Dart/Kotlin 侧一行日志、设置页「最近错误」都**不会**有痕迹，
/// 只有真机上才暴露（B04 卡住多轮的真因，见 work/reports/b04-trace.md）。
///
/// 这些是纯声明式配置，Dart 单测无法执行到，因此这里用静态断言把回归挡在代码级。
void main() {
  // `flutter test` 的工作目录是包根（repo/mobile），因此用相对路径读取真清单。
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';

  final manifest = File(manifestPath).readAsStringSync();

  /// 取出某个 receiver 的完整 XML 片段（自闭合或带 intent-filter 均可）。
  /// 找不到该 class 名时返回空串，交由调用方断言。
  String receiverBlock(String className) {
    final nameAt = manifest.indexOf(className);
    if (nameAt < 0) return '';
    final start = manifest.lastIndexOf('<receiver', nameAt);
    if (start < 0) return '';
    // 先定位这个 <receiver 开标签的结尾 '>'，再判断它是否自闭合（'/>'）。
    // 不能用 indexOf('/>') —— 内层 <action .../> 的自闭合会把块提前截断。
    final openEnd = manifest.indexOf('>', start);
    if (openEnd < 0) return '';
    final head = manifest.substring(start, openEnd + 1);
    if (head.endsWith('/>')) return head;
    final closeTag = manifest.indexOf('</receiver>', openEnd);
    if (closeTag < 0) return head;
    return manifest.substring(start, closeTag + '</receiver>'.length);
  }

  test('清单文件存在且是 App 的 main 清单', () {
    expect(File(manifestPath).existsSync(), isTrue,
        reason: '找不到 $manifestPath：请确认 flutter test 在 repo/mobile 下运行');
    expect(manifest, contains('<application'));
  });

  test('到点发通知的 ScheduledNotificationReceiver 已声明', () {
    final block = receiverBlock(
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver');
    expect(block, isNotEmpty,
        reason: '缺 ScheduledNotificationReceiver：闹钟到点后广播无处投递，'
            '通知永远不出现且应用侧零痕迹（B04）');
    expect(block, contains('android:exported="false"'),
        reason: '插件 README:254 要求 exported="false"');
  });

  test('开机重排的 ScheduledNotificationBootReceiver 已声明并监听开机/更新广播', () {
    final block = receiverBlock(
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver');
    expect(block, isNotEmpty,
        reason: '缺 ScheduledNotificationBootReceiver：重启/应用更新后已排的提醒不会重排');
    expect(block, contains('android:exported="false"'),
        reason: '插件 README:255 要求 exported="false"');
    expect(block, contains('android.intent.action.BOOT_COMPLETED'));
    expect(block, contains('android.intent.action.MY_PACKAGE_REPLACED'));
    expect(block, contains('android.intent.action.QUICKBOOT_POWERON'));
  });

  test('两个 receiver 都写在 <application> 内，且开机权限已声明', () {
    final appStart = manifest.indexOf('<application');
    final appEnd = manifest.indexOf('</application>');
    expect(appStart, greaterThanOrEqualTo(0));
    expect(appEnd, greaterThan(appStart));

    for (final className in const [
      'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver',
      'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver',
    ]) {
      final at = manifest.indexOf(className);
      expect(at, greaterThan(appStart), reason: '$className 必须在 <application> 之后');
      expect(at, lessThan(appEnd), reason: '$className 必须在 </application> 之前（写在应用外不生效）');
    }

    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'),
        reason: '缺 RECEIVE_BOOT_COMPLETED：BootReceiver 收不到开机广播');
  });

  test('短信导入已移除：READ_SMS 权限声明不再出现（v3 阶段 3）', () {
    expect(manifest, isNot(contains('android.permission.READ_SMS')),
        reason: 'READ_SMS 已随消息导入功能整体移除（design-v3 §3.2），'
            '重新加回意味着短信读取代码死灰复燃');
  });
}
