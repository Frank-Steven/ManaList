import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/junk_rules.dart';

Message _msg({
  String id = 'm1',
  String title = '',
  String body = '',
  String? sender,
}) =>
    Message(
      id: id,
      packageName: 'com.test',
      sender: sender,
      title: title,
      body: body,
      postedAt: 1700000000000,
      captureType: 'notification',
      contentHash: 'h-$id',
      createdAt: 1700000000000,
    );

void main() {
  group('junkRuleHit 本地垃圾规则', () {
    test('营销关键词命中标题', () {
      expect(junkRuleHit(_msg(title: '限时秒杀，全场五折')), isNotNull);
    });

    test('营销关键词命中正文', () {
      expect(junkRuleHit(_msg(body: '点击领取优惠券，先到先得')), isNotNull);
    });

    test('退订字样命中', () {
      expect(junkRuleHit(_msg(body: '回复TD退订')), isNotNull);
    });

    test('106 服务号含退订字样命中', () {
      expect(
          junkRuleHit(_msg(sender: '10690000123', body: '您的账单已出，回T退订')),
          isNotNull);
    });

    test('普通聊天不误伤', () {
      expect(junkRuleHit(_msg(title: '张三', body: '明天下午开会别忘了')), isNull);
    });

    test('106 服务号规则与普通关键词命中理由可区分', () {
      // 长服务号优先走服务号规则理由
      expect(
          junkRuleHit(_msg(sender: '10690000123', body: '您的账单已出，回T退订')),
          contains('运营服务号'));
      // 普通号码不适用服务号规则，但「退订」关键词仍命中（宁漏勿错）
      expect(junkRuleHit(_msg(sender: '张三', body: '回T退订')), contains('关键词'));
    });

    test('命中理由标注规则判定', () {
      final hit = junkRuleHit(_msg(body: '0元购火爆进行中'));
      expect(hit, startsWith('规则判定'));
    });
  });
}
