import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/attachment_cards.dart';

/// F22 回归（2026-11-11）：两张 1080×1440 / 各约 50KB 的截图曾被算成 **155%**
/// 并禁用发送 —— 根因是「文件字节数 / 2」被当成文本 token（51,200 字节 →
/// 25,600 token/张 → 两张 51,200 > 32,768）。
///
/// 修复口径：图片按**内联后的像素面积**估（长边缩到 1024，area/750），
/// 与文件字节数无关；宽高未知时回退保守上界 1,400/张。文本附件仍走「字符/2」。
void main() {
  group('estimateImageTokens（像素口径，不用字节）', () {
    test('1080×1440 → 缩到 768×1024 → 1049', () {
      expect(estimateImageTokens(width: 1080, height: 1440), 1049);
    });

    test('横向等比：1440×1080 → 1024×768 → 1049（比例不丢）', () {
      expect(estimateImageTokens(width: 1440, height: 1080), 1049);
    });

    test('800×800 未超长边上限 → 854', () {
      expect(estimateImageTokens(width: 800, height: 800), 854);
    });

    test('2048×2048 缩到 1024×1024 → 1399', () {
      expect(estimateImageTokens(width: 2048, height: 2048), 1399);
    });

    test('未知/非法宽高 → 保守上界 1400', () {
      expect(estimateImageTokens(), kConservativeImageTokens);
      expect(estimateImageTokens(width: 0, height: 100),
          kConservativeImageTokens);
      expect(estimateImageTokens(width: 100, height: -1),
          kConservativeImageTokens);
    });

    test('保守上界覆盖 1024 长边的最坏面积（1399 ≤ 1400）', () {
      expect(estimateImageTokens(width: 1024, height: 1024), 1399);
      expect(kConservativeImageTokens, greaterThanOrEqualTo(1399));
    });
  });

  group('sumAttachmentTokens（草稿合计分流）', () {
    const image = AttachmentMeta(
        title: 'Screenshot.jpg', icon: Icons.image, imageTokens: 1400);
    const text = AttachmentMeta(
        title: 'note.txt', icon: Icons.description, chars: 4000);

    test('两张截图 → 2800 token，不再触发超预算（修复前是 51,200）', () {
      expect(sumAttachmentTokens(const [image, image]), 2800);
      expect(budgetLevel(2800, kDefaultContextTokenLimit),
          BudgetLevel.normal);
    });

    test('修复前口径（字节/2）在两图时确实会 over —— 记录基线', () {
      const legacy = AttachmentMeta(
          title: 'Screenshot.jpg', icon: Icons.image, chars: 51200);
      expect(sumAttachmentTokens(const [legacy, legacy]), 51200);
      expect(budgetLevel(51200, kDefaultContextTokenLimit), BudgetLevel.over);
    });

    test('文本附件语义不变：字符/2', () {
      expect(sumAttachmentTokens(const [text]), 2000);
      expect(sumAttachmentTokens(const [image, text]), 3400);
    });

    test('元数据缺失按 0 计', () {
      expect(sumAttachmentTokens(const [null, image]), 1400);
      expect(sumAttachmentTokens(const [null]), 0);
      const empty = AttachmentMeta(title: 'x', icon: Icons.help_outline);
      expect(sumAttachmentTokens(const [empty]), 0);
    });

    test('图片同时带 chars 时以 imageTokens 为准（不会重复计）', () {
      const both = AttachmentMeta(
          title: 'x.jpg', icon: Icons.image, chars: 51200, imageTokens: 1049);
      expect(sumAttachmentTokens(const [both]), 1049);
    });
  });
}