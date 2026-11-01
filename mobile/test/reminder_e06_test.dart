import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_log.dart';
import 'package:msgrepo_mobile/services/reminder_service.dart';

/// E06 收尾（2026-10-25）：
/// - 失败统一留痕（lastError + debugPrint + AppLog），且**同错去重/限流**，
///   成功重排后解除去重；
/// - rescheduleAll 的早退 / 单条失败汇总 / 整体失败都走同一条口径；
/// - 编译期故障注入开关默认关，打开时只让**首次** init 失败，之后自动恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = ReminderService.instance;

  setUp(() {
    AppLog.instance.clear();
    svc.clearLastError();
    svc.clearErrorDedupe();
    svc.faultInjectEnabled = false;
  });

  tearDown(() {
    AppLog.instance.clear();
    svc.clearLastError();
    svc.clearErrorDedupe();
    svc.faultInjectEnabled = false;
  });

  group('recordError：统一留痕 + 同错去重', () {
    test('同一条错误重复 3 次：lastError 一直是最新，AppLog 只留 1 条', () {
      for (var i = 0; i < 3; i++) {
        svc.recordError('提醒排程失败 2 条，首个：任务「开会」排提醒失败：boom',
            scope: 'reminder.reschedule');
      }

      expect(svc.lastError, contains('排程失败'));
      expect(AppLog.instance.count, 1, reason: '同错只留一条，避免刷屏');
      expect(AppLog.instance.latest!.scope, 'reminder.reschedule');
    });

    test('不同错误各留 1 条', () {
      svc.recordError('错误 A');
      svc.recordError('错误 B');

      expect(AppLog.instance.count, 2);
    });

    test('被压掉的重复次数会累加进下一条新错误（不丢信息）', () {
      svc.recordError('E1');
      svc.recordError('E1');
      svc.recordError('E1');
      svc.recordError('E2');

      expect(AppLog.instance.count, 2);
      expect(AppLog.instance.latest!.message, contains('同类错误另有 2 次未重复记录'));
    });

    test('clearErrorDedupe 后同一条错误会重新记录，且不清 lastError', () {
      svc.recordError('E1');
      svc.recordError('E1'); // 被本服务的同错去重压掉
      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.repeats, 1);

      svc.clearErrorDedupe(); // 语义 = 重排成功，解除去重

      expect(svc.lastError, isNotNull, reason: '去重状态与 lastError 是两件事');

      svc.recordError('E1');
      // AppLog 自身对「同 scope + 同 message」是折叠计数（不新增条目）：
      // repeats 1 → 2 说明去重解除后确实又调了一次 AppLog.warn（否则仍是 1）。
      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.repeats, 2,
          reason: '成功一轮后的新失败必须重新留痕');
    });

    test('带异常对象时 AppLog 与 lastError 都包含详情，同错仍只记一次', () {
      svc.recordError('提醒重排失败', error: StateError('db locked'));
      svc.recordError('提醒重排失败', error: StateError('db locked'));

      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.message, contains('db locked'));
      expect(svc.lastError, contains('db locked'), reason: '设置页也要看到具体异常');
    });
  });

  group('rescheduleAll 失败路径走统一留痕', () {
    test('未初始化早退：lastError + AppLog 各一次，重复调用不刷屏', () async {
      expect(svc.initialized, isFalse, reason: '单测不应真正初始化平台插件');

      await svc.rescheduleAll();

      expect(svc.lastError, contains('未初始化'));
      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.scope, 'reminder.reschedule');

      await svc.rescheduleAll(); // 再来一轮：同错去重
      expect(AppLog.instance.count, 1, reason: '重复早退不应再刷一条');
    });

    test('noteInitFailure 走同一口径（scope=reminder.init，带异常详情）', () {
      svc.noteInitFailure(StateError('插件炸了'), StackTrace.empty);

      expect(svc.lastError, contains('提醒初始化失败'));
      expect(svc.lastError, contains('插件炸了'));
      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.scope, 'reminder.init');
    });
  });

  group('E06 故障注入开关', () {
    test('默认关闭：编译期常量与运行期开关都是 false', () {
      expect(ReminderService.faultInjectCompiled, isFalse,
          reason: '正常构建不允许注入');
      expect(svc.faultInjectEnabled, isFalse);
      expect(svc.consumeFaultInjection(), isFalse);
    });

    test('打开后 init 首次抛异常，且注入只消费一次（可恢复）', () async {
      svc.faultInjectEnabled = true;

      await expectLater(svc.init(), throwsA(isA<StateError>()));

      expect(svc.initialized, isFalse, reason: '注入发生在初始化副作用之前');
      expect(svc.consumeFaultInjection(), isFalse,
          reason: '注入只能生效一次，之后自动恢复');
    });
  });
}
