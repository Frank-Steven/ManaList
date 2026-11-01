import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/reminder_service.dart';

// E06（2026-10-24）：提醒初始化/调度失败必须可观测。
// 这些用例只验证「失败会不会留下痕迹」，不触碰任何平台通道，也不改变调度语义。
void main() {
  setUp(() {
    // 单例跨用例共享，每个用例前清空，避免互相污染。
    ReminderService.instance.clearLastError();
  });

  test('noteInitFailure 把失败原因写进 lastError，供设置页展示', () {
    final s = ReminderService.instance;
    expect(s.lastError, isNull, reason: '初始状态不应有错误');

    s.noteInitFailure(StateError('boom'));

    expect(s.lastError, isNotNull);
    expect(s.lastError, contains('提醒初始化失败'));
    expect(s.lastError, contains('boom'));
  });

  test('rescheduleAll 未初始化时不再静默早退，而是留下可诊断错误', () async {
    final s = ReminderService.instance;
    expect(s.initialized, isFalse, reason: '单测不应真正初始化平台插件');

    // 早退分支不会触碰插件/数据库，可安全直接调用。
    await s.rescheduleAll();

    expect(s.lastError, isNotNull);
    expect(s.lastError, contains('未初始化'));
    expect(s.lastError, contains('重排'));
  });

  test('clearLastError 能把最近错误清空（用户确认后）', () {
    final s = ReminderService.instance;
    s.noteInitFailure('x');
    expect(s.lastError, isNotNull);

    s.clearLastError();

    expect(s.lastError, isNull);
  });
}
