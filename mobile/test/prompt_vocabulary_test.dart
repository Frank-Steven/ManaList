import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/tools/inbox_triage.dart';

/// 提示词词汇一致性守卫：分类提示必须用输出 schema 的词汇（red/yellow/green/junk），
/// 不能再出现 v1 的 P0-P3 —— 两套词汇会让模型多一层无谓的映射负担。
/// （分类表已随批管线删除迁移进 inbox_triage.dart，阶段 7。）
void main() {
  test('所有分类 priorityHints 都不含 P0-P3', () {
    for (final c in kPromptCategories) {
      final hint = c.priorityHints ?? '';
      expect(RegExp(r'P[0-3]').hasMatch(hint), isFalse,
          reason: '${c.key} 的提示仍在用 v1 词汇：$hint');
    }
  });

  test('营销/验证码的措辞与输出语义对齐', () {
    final coupon =
        kPromptCategories.firstWhere((c) => c.key == 'coupon');
    expect(coupon.priorityHints, contains('junk'), reason: '营销应明确指向 junk');
    final code =
        kPromptCategories.firstWhere((c) => c.key == 'verification');
    expect(code.priorityHints, contains('red'), reason: '验证码应明确指向 red');
  });
}
