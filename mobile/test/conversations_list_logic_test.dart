import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/ui/assistant/conversations_page.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/attachment_cards.dart';

/// v4 批次 D 纯逻辑：相对时间、通道状态点、搜索高亮/片段、
/// 自动命名、附件预算档。
void main() {
  group('relativeConversationTime（§2.2）', () {
    final now = DateTime(2026, 11, 8, 15, 30);
    test('当天 HH:mm / 昨天 / N 天前 / 更早 MM-dd', () {
      expect(relativeConversationTime(
          DateTime(2026, 11, 8, 9, 5).millisecondsSinceEpoch, now), '09:05');
      expect(relativeConversationTime(
          DateTime(2026, 11, 7, 23, 59).millisecondsSinceEpoch, now), '昨天');
      expect(relativeConversationTime(
          DateTime(2026, 11, 5, 12, 0).millisecondsSinceEpoch, now), '3 天前');
      expect(relativeConversationTime(
          DateTime(2026, 10, 1, 12, 0).millisecondsSinceEpoch, now), '10-01');
    });
  });

  group('conversationChannelStatus（§2.2 状态点）', () {
    const brokenRemote = AiEndpoint(
        id: 'e1',
        name: 'A',
        baseUrl: 'https://a.com',
        lastError: 'HTTP 401');
    const okRemote =
        AiEndpoint(id: 'e2', name: 'B', baseUrl: 'https://b.com');

    test('默认路由：LinkModel 在线绿；离线有默认远程灰；都没有红', () {
      expect(
          conversationChannelStatus(
              modelConfigId: null,
              desktopOnline: true,
              isKnownDesktopModel: false,
              boundRemote: null,
              hasDefaultRemote: true),
          ChannelStatus.online);
      expect(
          conversationChannelStatus(
              modelConfigId: '',
              desktopOnline: false,
              isKnownDesktopModel: false,
              boundRemote: null,
              hasDefaultRemote: true),
          ChannelStatus.standby);
      expect(
          conversationChannelStatus(
              modelConfigId: null,
              desktopOnline: false,
              isKnownDesktopModel: false,
              boundRemote: null,
              hasDefaultRemote: false),
          ChannelStatus.broken);
    });

    test('绑定远程：最近测试失败红，否则灰', () {
      expect(
          conversationChannelStatus(
              modelConfigId: 'e1',
              desktopOnline: false,
              isKnownDesktopModel: false,
              boundRemote: brokenRemote,
              hasDefaultRemote: true),
          ChannelStatus.broken);
      expect(
          conversationChannelStatus(
              modelConfigId: 'e2',
              desktopOnline: false,
              isKnownDesktopModel: false,
              boundRemote: okRemote,
              hasDefaultRemote: true),
          ChannelStatus.standby);
    });

    test('绑定桌面模型：在线绿、离线灰；在线但列表已无不识 → 红（失效）', () {
      expect(
          conversationChannelStatus(
              modelConfigId: 'dm-1',
              desktopOnline: true,
              isKnownDesktopModel: true,
              boundRemote: null,
              hasDefaultRemote: false),
          ChannelStatus.online);
      expect(
          conversationChannelStatus(
              modelConfigId: 'dm-1',
              desktopOnline: false,
              isKnownDesktopModel: false,
              boundRemote: null,
              hasDefaultRemote: false),
          ChannelStatus.standby,
          reason: '离线时无法确认，不谎报失效');
      expect(
          conversationChannelStatus(
              modelConfigId: 'dm-gone',
              desktopOnline: true,
              isKnownDesktopModel: false,
              boundRemote: null,
              hasDefaultRemote: false),
          ChannelStatus.broken);
    });
  });

  group('highlightSpans / makeSearchSnippet（§2.3）', () {
    const hit = TextStyle(fontWeight: FontWeight.bold);
    test('大小写不敏感切段，多段命中', () {
      final spans = highlightSpans('买牛奶和Milk', '牛奶', hit);
      expect(spans.map((s) => s.text).join(), '买牛奶和Milk');
      expect(spans[1].text, '牛奶');
      expect(spans[1].style, hit);
      final spans2 = highlightSpans('MILK milk', 'milk', hit);
      expect(spans2.where((s) => s.style == hit).length, 2);
    });

    test('片段截取：命中词前后留上下文，首尾补省略号', () {
      final long = '前文${'很长' * 20}牛奶${'后文' * 20}';
      final snip = makeSearchSnippet(long, '牛奶');
      expect(snip, contains('牛奶'));
      expect(snip, startsWith('…'));
      expect(snip, endsWith('…'));
      // 未命中（防御分支）：截开头
      expect(makeSearchSnippet('短文本', 'x'), '短文本');
    });
  });

  group('deriveConversationTitle（§9 自动命名 / F37 新口径）', () {
    test('折叠空白 + trim，保留全文（不再按 20 字截断存库）', () {
      expect(deriveConversationTitle('  帮我整理收件箱  '), '帮我整理收件箱');
      // F37：21 字标题必须完整保留，否则顶栏永远不可能溢出滚动
      const long21 = 'think step by step about it';
      expect(deriveConversationTitle(long21), long21);
      expect(deriveConversationTitle(long21).endsWith('…'), isFalse);
      // 换行/连续空白折叠成单空格
      expect(deriveConversationTitle('第一行\n\n第二行   第三行'), '第一行 第二行 第三行');
      expect(deriveConversationTitle('   '), '');
    });

    test('只有超过 120 字符才截断加省略号', () {
      final a = 'a' * kConversationTitleMaxLength;
      expect(deriveConversationTitle(a), a);
      final b = 'b' * (kConversationTitleMaxLength + 1);
      final out = deriveConversationTitle(b);
      expect(out.length, kConversationTitleMaxLength + 1);
      expect(out.endsWith('…'), isTrue);
      expect(out.substring(0, kConversationTitleMaxLength), b.substring(0, kConversationTitleMaxLength));
    });
  });

  group('附件预算档（§3.6）', () {
    test('token 估算 = 字符数/2 上取整', () {
      expect(estimateTokensFromChars(100), 50);
      expect(estimateTokensFromChars(101), 51);
      expect(estimateTokensFromChars(0), 0);
    });

    test('≤80% 灰 / >80% amber / >100% 红', () {
      expect(budgetLevel(0, 32768), BudgetLevel.normal);
      expect(budgetLevel(26214, 32768), BudgetLevel.normal,
          reason: '恰好 80% 仍正常');
      expect(budgetLevel(26215, 32768), BudgetLevel.warning);
      expect(budgetLevel(32769, 32768), BudgetLevel.over);
      expect(budgetLevel(10, 0), BudgetLevel.normal,
          reason: '上限无效时降级不拦发送');
    });
  });
}
