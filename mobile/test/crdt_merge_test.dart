import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/crdt.dart';

/// CRDT 纯函数性质（crdt.md §2/§4）：
/// actor 决胜序 user > system > assistant；LWW 比较键
/// (lamport, actorRank, actor 字典序, opId) 的全序性质。
void main() {
  OpStamp stamp(int lamport, String actor, [String opId = 'op']) =>
      OpStamp(lamport: lamport, actor: actor, opId: opId);

  group('actorRank', () {
    test('user > system > assistant:*', () {
      expect(actorRank(OpActor.user), greaterThan(actorRank(OpActor.system)));
      expect(actorRank(OpActor.system),
          greaterThan(actorRank(OpActor.assistant('c1'))));
      expect(actorRank(OpActor.assistant('a')),
          actorRank(OpActor.assistant('b')), reason: '助理同级');
    });
  });

  group('lwwWins', () {
    test('lamport 大者赢（跨 actor）', () {
      // 助理的更新 op 赢过人的旧 op —— LWW 先行，决胜序只管同刻
      expect(
          lwwWins(stamp(2, OpActor.assistant('c1')), stamp(1, OpActor.user)),
          isTrue);
      expect(
          lwwWins(stamp(1, OpActor.user), stamp(2, OpActor.assistant('c1'))),
          isFalse);
    });

    test('同 lamport：人赢系统、系统赢助理、人赢助理', () {
      expect(lwwWins(stamp(1, OpActor.user), stamp(1, OpActor.system)), isTrue);
      expect(lwwWins(stamp(1, OpActor.system), stamp(1, OpActor.user)),
          isFalse);
      expect(lwwWins(stamp(1, OpActor.system), stamp(1, OpActor.assistant('c'))),
          isTrue);
      expect(lwwWins(stamp(1, OpActor.user), stamp(1, OpActor.assistant('c'))),
          isTrue);
    });

    test('同 lamport 同 rank：actor 字典序决胜（两助理并发确定收敛）', () {
      final a = stamp(3, OpActor.assistant('aaa'));
      final b = stamp(3, OpActor.assistant('bbb'));
      expect(lwwWins(b, a), isTrue);
      expect(lwwWins(a, b), isFalse);
    });

    test('完全同刻同 actor：opId 决胜，保证严格全序（无并列）', () {
      final a = stamp(3, OpActor.user, 'op-a');
      final b = stamp(3, OpActor.user, 'op-b');
      expect(lwwWins(b, a), isTrue);
      expect(lwwWins(a, b), isFalse);
    });

    test('current 为 null 时必赢；自身不赢自身（幂等）', () {
      expect(lwwWins(stamp(1, OpActor.user), null), isTrue);
      final s = stamp(1, OpActor.user);
      expect(lwwWins(s, s), isFalse);
    });

    test('反对称性：a 赢 b 当且仅当 b 不赢 a（随机抽样式全序检查）', () {
      final actors = [OpActor.user, OpActor.system, OpActor.assistant('x')];
      for (final la in [1, 2]) {
        for (final lb in [1, 2]) {
          for (final aa in actors) {
            for (final ab in actors) {
              for (final (oa, ob) in [('p', 'q'), ('q', 'p')]) {
                final sa = stamp(la, aa, oa);
                final sb = stamp(lb, ab, ob);
                if (sa == sb) continue;
                expect(lwwWins(sa, sb), isNot(lwwWins(sb, sa)),
                    reason: '$sa vs $sb 必须严格一方赢');
              }
            }
          }
        }
      }
    });
  });

  group('target 寻址', () {
    test('字段与前缀寻址串', () {
      expect(taskFieldTarget('t1', 'title'), 'tasks:t1:title');
      expect(taskPrefix('t1'), 'tasks:t1:');
      expect(messageFieldTarget('m1', 'priority'), 'messages:m1:priority');
      expect(noteFieldTarget('n1', 'content'), 'notes:n1:content');
      expect(anchorSetTarget('t1'), 'anchors:t1');
      expect(taskFieldTarget('t1', 'title'), startsWith(taskPrefix('t1')));
    });
  });

  group('OpStamp JSON 往返', () {
    test('toJson/fromJson 一致', () {
      final s = stamp(7, OpActor.assistant('c1'), 'op-123');
      expect(OpStamp.fromJson(s.toJson()), s);
    });
  });
}
