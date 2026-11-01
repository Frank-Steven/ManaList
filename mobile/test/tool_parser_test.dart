import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_service.dart';
import 'package:msgrepo_mobile/services/assistant/tool_parser.dart';

/// 工具调用块流式解析状态机（design-v3-details §2.2）：
/// 围栏状态机、容错（```json 误标/多余空白）、流中断丢弃、去重键。
void main() {
  group('围栏状态机（TEXT → IN_BLOCK → TEXT）', () {
    test('文本与工具块交错：文本上屏、块解析', () {
      final p = ToolBlockParser();
      final r = p.feed('好的，我来建任务。\n```tool\n'
          '{"tool":"task.create","args":{"title":"买菜"}}\n'
          '```\n就这些。\n');
      expect(r.text, '好的，我来建任务。\n就这些。\n');
      expect(r.blocks.single.tool, 'task.create');
      expect(r.blocks.single.args, {'title': '买菜'});
      expect(r.blocks.single.index, 0);
    });

    test('一块一个原子调用，一个回合多个块，blockIndex 递增', () {
      final p = ToolBlockParser();
      final r = p.feed('```tool\n{"tool":"task.create","args":{"title":"A"}}\n```\n'
          '说明文字\n'
          '```tool\n{"tool":"task.create","args":{"title":"B"}}\n```\n');
      expect(r.text, '说明文字\n');
      expect(r.blocks.length, 2);
      expect(r.blocks[0].index, 0);
      expect(r.blocks[1].index, 1);
      expect(p.blockCount, 2);
    });

    test('增量喂入：围栏跨 chunk 拆分仍正确', () {
      final p = ToolBlockParser();
      final r1 = p.feed('前半\n``');
      expect(r1.text, '前半\n', reason: '完整行立即上屏');
      final r2 = p.feed('`tool\n{"tool":"note.read",');
      expect(r2.text, '', reason: '含反引号的尾行暂存，围栏不被拆坏');
      expect(p.inBlock, isTrue);
      final r3 = p.feed('"args":{"noteId":"n1"}}\n```\n后半');
      expect(r3.blocks.single.tool, 'note.read');
      expect(r3.text, '后半', reason: '块闭合后的无反引号尾行立即上屏');
      final fin = p.finish();
      expect(fin.text, '');
    });

    test('TEXT 段增量上屏：不含反引号的尾行不等到换行', () {
      final p = ToolBlockParser();
      final r = p.feed('没有换行的流式文字');
      expect(r.text, '没有换行的流式文字');
      final fin = p.finish();
      expect(fin.text, '');
    });

    test('非 tool/json 的代码块是普通文本', () {
      final p = ToolBlockParser();
      final r = p.feed('```dart\nvoid main() {}\n```\n');
      expect(r.blocks, isEmpty);
      expect(r.text, contains('void main()'));
    });
  });

  group('容错（details §2.1）', () {
    test('```json 误标也按工具块解析', () {
      final p = ToolBlockParser();
      final r = p.feed('```json\n{"tool":"task.list","args":{}}\n```\n');
      expect(r.blocks.single.tool, 'task.list');
      expect(r.blocks.single.args, isEmpty);
    });

    test('围栏行多余空白容忍', () {
      final p = ToolBlockParser();
      final r = p.feed('  ```tool  \n{"tool":"task.list","args":{}}\n   ```   \n');
      expect(r.blocks.single.tool, 'task.list');
    });

    test('坏 JSON：块带 parseError 丢弃，文本流不中断', () {
      final p = ToolBlockParser();
      final r = p.feed('前文\n```tool\n{bad json,}\n```\n后文\n');
      expect(r.blocks.single.ok, isFalse);
      expect(r.blocks.single.parseError, contains('JSON 解析失败'));
      expect(r.text, '前文\n后文\n');
    });

    test('缺 tool 字段 / 非对象块被拒绝', () {
      final p = ToolBlockParser();
      final r = p.feed('```tool\n{"args":{}}\n```\n```tool\n[1,2]\n```\n');
      expect(r.blocks[0].parseError, contains('缺少 tool'));
      expect(r.blocks[1].parseError, contains('JSON 对象'));
      // args 非对象
      final p2 = ToolBlockParser();
      final r2 = p2.feed('```tool\n{"tool":"task.list","args":[1]}\n```\n');
      expect(r2.blocks.single.ok, isFalse);
      expect(r2.blocks.single.parseError, contains('args'));
    });
  });

  group('流中断（details §2.2）', () {
    test('未闭合块整体丢弃，已闭合块保留', () {
      final p = ToolBlockParser();
      final r = p.feed('文本\n```tool\n{"tool":"task.create","args":{"title":"A"}}\n```\n');
      expect(r.blocks.single.tool, 'task.create');
      final r2 = p.feed('```tool\n{"tool":"task.delete","args":{"id"');
      expect(r2.blocks, isEmpty);
      expect(p.inBlock, isTrue);
      final fin = p.finish(interrupted: true);
      expect(fin.discardedUnclosedBlock, isTrue);
      expect(fin.blocks, isEmpty, reason: '中断时未闭合块不产出');
      expect(fin.text, isEmpty, reason: '块内残片不上屏');
    });

    test('正常结束时的未闭合块同样丢弃（缺闭合围栏不可信）', () {
      final p = ToolBlockParser();
      p.feed('```tool\n{"tool":"task.create","args":{"title":"A"}}\n');
      final fin = p.finish();
      expect(fin.blocks, isEmpty);
      expect(fin.discardedUnclosedBlock, isFalse, reason: '非中断语义不置标志');
    });

    test('尾行闭合围栏无换行也算闭合', () {
      final p = ToolBlockParser();
      p.feed('```tool\n{"tool":"task.list","args":{}}\n```');
      final fin = p.finish();
      expect(fin.blocks.single.tool, 'task.list');
    });
  });

  group('去重键 (chatMessageId, blockIndex)（details §2.3）', () {
    test('提案 id = <batchId>_b<blockIndex>，同回合重放命中主键', () {
      expect(ProposalService.proposalIdFor('msg-1', 0), 'msg-1_b0');
      expect(ProposalService.proposalIdFor('msg-1', 3), 'msg-1_b3');
      // 两个解析器实例（重放）对同一消息产出相同的 id 序列
      String feedAll(ToolBlockParser p, String s) {
        final ids = <String>[];
        for (final b in p.feed(s).blocks) {
          ids.add(ProposalService.proposalIdFor('msg-9', b.index));
        }
        return ids.join(',');
      }

      const replay = '```tool\n{"tool":"task.list","args":{}}\n```\n'
          '```tool\n{"tool":"task.list","args":{}}\n```\n';
      expect(feedAll(ToolBlockParser(), replay),
          feedAll(ToolBlockParser(), replay));
    });
  });
}
