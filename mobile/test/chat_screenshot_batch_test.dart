import 'package:flutter_test/flutter_test.dart';

import 'package:msgrepo_mobile/ui/assistant/chat_page.dart';

/// F03（2026-11-03）Step1+2 的纯函数守卫：单批上限、超限截断、约定文案。
void main() {
  group('F03 相册截图批量', () {
    test('单批上限是 6', () {
      expect(maxScreenshotsPerBatch, 6);
    });

    test('不超过上限时原样返回（且不共享同一实例）', () {
      final picked = List<int>.generate(maxScreenshotsPerBatch, (i) => i);
      final out = clampScreenshotBatch(picked);
      expect(out, picked);
      expect(identical(out, picked), isFalse);
    });

    test('超出上限只取前 6 张，其余留给用户分批', () {
      final picked = List<int>.generate(9, (i) => i);
      final out = clampScreenshotBatch(picked);
      expect(out.length, maxScreenshotsPerBatch);
      expect(out, [0, 1, 2, 3, 4, 5]);
    });

    test('空列表与超上限的边界', () {
      expect(clampScreenshotBatch<int>(const []), isEmpty);
      expect(clampScreenshotBatch<int>(List.generate(7, (i) => i)).length, 6);
    });
  });

  group('F03 截图整理约定文案', () {
    test('包含单张成条、待办/笔记产物与不跨图合并', () {
      final hint = screenshotsConventionHint();
      expect(hint, contains('每张截图单独成条'));
      expect(hint, contains('task.create'));
      expect(hint, contains('note.create'));
      expect(hint, contains('不跨图合并'));
    });

    test('包含敏感信息离设备提示', () {
      final hint = screenshotsConventionHint();
      expect(hint, contains('敏感信息'));
      expect(hint, contains('离开设备'));
    });
  });
}
