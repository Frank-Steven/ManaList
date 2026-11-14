import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/attachment_cards.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/input_bar.dart';

/// B32 回归（2026-11-14）：挂上附件后不即时重算 + 卡片标题显示 UUID。
///
/// 根因：`_pickAttachments()` 只 setState + 落库，没调 `_resolveAttachmentMeta()`；
/// 于是 `_metaOf(a)` 为 null → 预算算 0、卡片标题回退成 `a.id`（UUID）。
/// 修复：草稿附件写入收敛到 `_applyPendingAttachments()`（setState + 落库 + resolve），
/// 并且 meta 未解析时标题显示占位「正在读取…」而不是 UUID。
void main() {
  const uuid = '26789c30-ab0d-4bc5-bc7f-371234567890';
  const attach = ChatAttachment(type: ChatAttachmentType.file, id: uuid);

  Widget cardHarness(AttachmentMeta? meta) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
                width: 210,
                height: 132,
                child: AttachmentCard(attachment: attach, meta: meta)),
          ),
        ),
      );

  group('附件卡片标题兜底（不输出 UUID）', () {
    testWidgets('meta 为空 → 显示「正在读取…」，不含 UUID 形态串',
        (tester) async {
      await tester.pumpWidget(cardHarness(null));
      expect(find.text('正在读取…'), findsOneWidget);
      expect(find.textContaining(uuid), findsNothing);
      expect(
          find.textContaining(RegExp(
              r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}')),
          findsNothing,
          reason: 'B32：UUID 不得被当成文件名展示');
    });

    testWidgets('meta 解析完成后自然替换成真实标题', (tester) async {
      const meta = AttachmentMeta(
          title: 'f03-B.png', icon: Icons.image_outlined);
      await tester.pumpWidget(cardHarness(meta));
      expect(find.text('f03-B.png'), findsOneWidget);
      expect(find.text('正在读取…'), findsNothing);
    });
  });

  group('草稿 chip 标题兜底', () {
    Widget chipHarness(AttachmentMeta? Function(ChatAttachment) metaOf) =>
        MaterialApp(
          home: Scaffold(
            body: ChatInputBar(
              controller: TextEditingController(),
              busy: false,
              attachments: const [attach],
              metaOf: metaOf,
              onRemoveAttachment: (_) {},
              onAddAttachments: () {},
              onPickScreenshots: () {},
              onSend: () {},
              onCancel: () {},
            ),
          ),
        );

    testWidgets('metaOf 返回 null → chip 显示「正在读取…」，不含 UUID',
        (tester) async {
      await tester.pumpWidget(chipHarness((_) => null));
      expect(find.text('正在读取…'), findsOneWidget);
      expect(find.textContaining(uuid), findsNothing);
    });

    testWidgets('metaOf 有值时 chip 显示真实标题', (tester) async {
      await tester.pumpWidget(chipHarness((_) => const AttachmentMeta(
          title: 'f03-B.png', icon: Icons.image_outlined)));
      expect(find.text('f03-B.png'), findsOneWidget);
      expect(find.text('正在读取…'), findsNothing);
    });
  });

  group('预算随 meta 立即出现（机制断言）', () {
    test('meta 未解析 → 0；解析出图片 → 立即 1400（write 后必须 resolve）', () {
      // 这是 B32 的可观测后果：附件写入后若不 resolve，_metaOf 为 null，合计算 0。
      const imageMeta = AttachmentMeta(
          title: 'f03-B.png',
          icon: Icons.image_outlined,
          imageTokens: kConservativeImageTokens);
      expect(sumAttachmentTokens(const [null]), 0);
      expect(sumAttachmentTokens(const [imageMeta]), 1400);
    });
  });
}