import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_name_service.dart';

/// 应用名懒解析（ux-fixes-2026-11 §2.1）：needsResolution 判定口径 +
/// resolve 的失败分类（包不存在记忆 null；瞬时失败不记忆、下次重试）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = AppNameService.instance;

  setUp(svc.debugReset);

  group('needsResolution', () {
    test('null / 空白 / 等于包名 → 需要重解析', () {
      expect(AppNameService.needsResolution(null, 'com.x'), isTrue);
      expect(AppNameService.needsResolution('', 'com.x'), isTrue);
      expect(AppNameService.needsResolution('   ', 'com.x'), isTrue);
      expect(AppNameService.needsResolution('com.x', 'com.x'), isTrue);
    });

    test('正常名称 → 不重解析', () {
      expect(AppNameService.needsResolution('微信', 'com.tencent.mm'), isFalse);
    });
  });

  group('resolve', () {
    test('解析成功：记忆结果，第二次不再取通道', () async {
      var calls = 0;
      svc.fetcherOverride = (_) async {
        calls++;
        return '微信';
      };
      expect(await svc.resolve('com.tencent.mm'), '微信');
      expect(await svc.resolve('com.tencent.mm'), '微信');
      expect(calls, 1);
      expect(svc.cached('com.tencent.mm'), '微信');
    });

    test('包不存在：记忆 null，不再重试', () async {
      var calls = 0;
      svc.fetcherOverride = (pkg) async {
        calls++;
        throw AppNameNotFoundException(pkg);
      };
      expect(await svc.resolve('gone.app'), isNull);
      expect(await svc.resolve('gone.app'), isNull);
      expect(calls, 1);
    });

    test('瞬时失败：不记忆，下次重试成功', () async {
      var calls = 0;
      svc.fetcherOverride = (_) async {
        calls++;
        if (calls == 1) throw StateError('transient');
        return 'QQ';
      };
      expect(await svc.resolve('com.tencent.mobileqq'), isNull);
      expect(await svc.resolve('com.tencent.mobileqq'), 'QQ');
      expect(calls, 2);
    });

    test('平台返回空串/包名：按未解析处理，不记忆', () async {
      svc.fetcherOverride = (pkg) async => pkg;
      expect(await svc.resolve('com.x'), isNull);
      svc.fetcherOverride = (_) async => '  ';
      expect(await svc.resolve('com.x'), isNull);
    });
  });
}
