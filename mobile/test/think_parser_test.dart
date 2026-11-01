import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/think_parser.dart';

void main() {
  group('ThinkTagParser', () {
    test('无思考标签：文本原样通过', () {
      final p = ThinkTagParser();
      final r = p.feed('你好，世界');
      expect(r.text, '你好，世界');
      expect(r.thinkingChanged, isFalse);
      expect(p.hasThinking, isFalse);
    });

    test('完整思考块：内容进思考缓冲，不上屏', () {
      final p = ThinkTagParser();
      final r = p.feed('<think>先想想</think>回答');
      // 标签外文本放行（“回答”可能被尾部保护逻辑暂存，finish 后检查）
      final tail = p.finish();
      expect('${r.text}${tail.text}', contains('回答'));
      expect(p.thinking, '先想想');
      expect(p.inThinking, isFalse);
      expect(p.sectionIndex, 0);
      expect(p.sectionThinking, '先想想');
    });

    test('标签跨 chunk 拆分：前缀暂存不误判', () {
      final p = ThinkTagParser();
      final r1 = p.feed('前面<th');
      expect(r1.text, '前面'); // '<th' 可能是标签前缀，暂存
      final r2 = p.feed('ink>推理');
      expect(r2.text, isEmpty);
      expect(p.inThinking, isTrue);
      final r3 = p.feed('过程</thi');
      final r4 = p.feed('nk>正文');
      expect(p.thinking, contains('推理过程'));
      expect(p.inThinking, isFalse);
      expect('${r3.text}${r4.text}${p.finish().text}', contains('正文'));
    });

    test('多次思考分段：section 递增、各段内容独立', () {
      final p = ThinkTagParser();
      p.feed('<think>一</think>答一');
      p.feed('<think>二</think>答二');
      expect(p.sectionIndex, 1);
      expect(p.sectionThinking, '二');
      expect(p.thinking, '一二');
    });

    test('finish：中断在思考块内，暂存按思考内容落出', () {
      final p = ThinkTagParser();
      p.feed('<think>没想完</th');
      final tail = p.finish();
      expect(p.thinking, '没想完</th');
      expect(tail.text, isEmpty);
    });

    test('正文中孤立的 < 不误吞', () {
      final p = ThinkTagParser();
      final r = p.feed('a < b 且 c <think');
      // 尾部 '<think' 缺 '>'：按标签前缀暂存，尚未进入思考
      expect(r.text, 'a < b 且 c ');
      expect(p.inThinking, isFalse);
      // 补上 '>' 后标签生效；若实际不是标签，finish 时按普通文本落出
      p.feed('>推理</think>');
      expect(p.inThinking, isFalse);
      expect(p.thinking, '推理');
    });
  });
}
