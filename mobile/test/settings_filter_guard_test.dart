import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_filter_service.dart';
import 'package:msgrepo_mobile/ui/settings_page.dart';

/// B03：切「仅指定应用」时的防呆逻辑。
///
/// 数据层契约不变（空 allowlist 仍全拦截，见 app_filter_test.dart），
/// 这里只保证 UI 层不会**静默**把用户切进「一条通知都不采集」的状态：
/// 名单为空时先要求选应用，没选就保持原模式。
void main() {
  group('filterNeedsAppSelection：何时必须先选应用', () {
    test('切到 allowlist 且名单为空 → 需要先选', () {
      expect(filterNeedsAppSelection(AppFilterConfig.modeAllowlist, const []),
          isTrue);
    });

    test('切到 allowlist 但已有名单 → 直接切', () {
      expect(
          filterNeedsAppSelection(
              AppFilterConfig.modeAllowlist, const ['com.tencent.mm']),
          isFalse);
    });

    test('切到 all / blacklist 不需要先选（空 blacklist 无害）', () {
      expect(filterNeedsAppSelection(AppFilterConfig.modeAll, const []),
          isFalse);
      expect(filterNeedsAppSelection(AppFilterConfig.modeBlacklist, const []),
          isFalse);
    });
  });

  group('filterConfigAfterSelection：选择结果怎么落库', () {
    test('取消（null）→ 返回 null，调用方保持原模式', () {
      expect(
          filterConfigAfterSelection(
              currentPackages: const [], picked: null),
          isNull);
    });

    test('一个都没勾（空集合）→ 返回 null，不能切成空 allowlist', () {
      expect(
          filterConfigAfterSelection(
              currentPackages: const [], picked: <String>{}),
          isNull);
    });

    test('勾了应用 → 落成 allowlist 并带上所选包名', () {
      final cfg = filterConfigAfterSelection(
          currentPackages: const [], picked: {'com.tencent.mm'});
      expect(cfg, isNotNull);
      expect(cfg!.mode, AppFilterConfig.modeAllowlist);
      expect(cfg.packages, ['com.tencent.mm']);
      // 防呆目标：落库后确实会采集所选应用
      expect(cfg.allows('com.tencent.mm'), isTrue);
      expect(cfg.allows('com.other'), isFalse);
    });

    test('已有包名时合并去重（不丢掉先前选过的）', () {
      final cfg = filterConfigAfterSelection(
          currentPackages: const ['com.tencent.mm'],
          picked: {'com.tencent.mobileqq'});
      expect(cfg!.packages..sort(), ['com.tencent.mm', 'com.tencent.mobileqq']);
      expect(cfg.mode, AppFilterConfig.modeAllowlist);
    });
  });
}
