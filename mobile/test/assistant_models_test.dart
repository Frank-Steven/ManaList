import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';

void main() {
  const anchorId = '123e4567-e89b-42d3-a456-426614174000';

  group('锚点 marker 正则（design-v3-details §1.1）', () {
    test('匹配标准小写 uuid marker', () {
      final m = anchorMarkerPattern.firstMatch('⟦task:$anchorId⟧');
      expect(m, isNotNull);
      expect(m!.group(1), anchorId);
    });

    test('读取大小写容忍', () {
      final upper = anchorId.toUpperCase();
      expect(anchorMarkerPattern.hasMatch('⟦task:$upper⟧'), isTrue);
    });

    test('拒绝非 uuid 内容', () {
      expect(anchorMarkerPattern.hasMatch('⟦task:not-a-uuid⟧'), isFalse);
      expect(anchorMarkerPattern.hasMatch('⟦task:⟧'), isFalse);
      expect(anchorMarkerPattern.hasMatch('[task:$anchorId]'), isFalse);
    });

    test('同一正文可含多个 marker', () {
      const other = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      const text = '前文⟦task:$anchorId⟧中间⟦task:$other⟧后文';
      expect(anchorMarkerPattern.allMatches(text).length, 2);
    });
  });

  group('anchorMarker / stripAnchorMarkers', () {
    test('anchorMarker 生成与正则往返', () {
      final marker = anchorMarker(anchorId);
      expect(marker, '⟦task:$anchorId⟧');
      expect(anchorMarkerPattern.firstMatch(marker)!.group(1), anchorId);
    });

    test('strip 剥离全部 marker，保留其余文本', () {
      const text = '买菜⟦task:$anchorId⟧记得带袋子';
      expect(stripAnchorMarkers(text), '买菜记得带袋子');
    });

    test('strip 不做空白折叠', () {
      const text = 'a ⟦task:$anchorId⟧ b';
      expect(stripAnchorMarkers(text), 'a  b');
    });

    test('无 marker 文本原样返回', () {
      const text = '纯文本内容';
      expect(stripAnchorMarkers(text), text);
    });
  });

  group('ChatEvent 解析（chat-response.schema.json）', () {
    test('token_delta', () {
      final e = ChatEvent.parseLine('{"type":"token_delta","delta":"你好"}');
      expect(e, isA<ChatTokenDelta>());
      expect((e as ChatTokenDelta).delta, '你好');
    });

    test('proposal 含 proposalId / tool / args', () {
      final e = ChatEvent.parseLine(
          '{"type":"proposal","proposalId":"$anchorId","tool":"task.create","args":{"title":"买菜"}}');
      expect(e, isA<ChatProposalEvent>());
      final p = e as ChatProposalEvent;
      expect(p.proposalId, anchorId);
      expect(p.tool, 'task.create');
      expect(p.args['title'], '买菜');
    });

    test('done / error', () {
      expect(ChatEvent.parseLine('{"type":"done"}'), isA<ChatDone>());
      final e = ChatEvent.parseLine('{"type":"error","error":"网络中断"}');
      expect((e as ChatError).error, '网络中断');
    });

    test('未知类型抛 FormatException', () {
      expect(() => ChatEvent.parseLine('{"type":"bogus"}'),
          throwsFormatException);
    });

    test('toJson 往返', () {
      const p = ChatProposalEvent(
          proposalId: 'p1', tool: 'note.append', args: {'noteId': 'n1'});
      final restored = ChatEvent.fromJson(p.toJson()) as ChatProposalEvent;
      expect(restored.proposalId, 'p1');
      expect(restored.tool, 'note.append');
      expect(restored.args, {'noteId': 'n1'});
    });
  });

  group('TaskAnchor / ModelConfig / ChangeProposal JSON 往返', () {
    test('TaskAnchor label 可空', () {
      final a = TaskAnchor.fromJson(const TaskAnchor(
        id: 'a1',
        taskId: 't1',
        targetType: AnchorTargetType.note,
        targetId: 'n1',
        createdBy: AnchorCreatedBy.ai,
        createdAt: 1000,
      ).toJson());
      expect(a.label, isNull);
      expect(a.targetType, 'note');
      expect(a.createdBy, 'ai');
    });

    test('ModelConfig apiKeyEnv 可选', () {
      final m = ModelConfig.fromJson(const ModelConfig(
        id: 'local-gemma',
        name: 'Gemma 4 26B (本地)',
        provider: ModelProvider.openaiCompat,
        baseUrl: 'http://127.0.0.1:8080/v1',
        model: 'gemma-4-26b-a4b-it',
      ).toJson());
      expect(m.provider, 'openai-compat');
      expect(m.apiKeyEnv, isNull);
    });

    test('ChangeProposal 缺省 pending 且含 batchId / status', () {
      const p = ChangeProposal(
        id: 'p1',
        conversationId: 'c1',
        batchId: 'm1',
        tool: 'task.create',
        summary: '新建任务「买菜」',
        payload: {'title': '买菜'},
        createdAt: 1000,
      );
      expect(p.status, ProposalStatus.pending);
      final restored = ChangeProposal.fromJson(p.toJson());
      expect(restored.batchId, 'm1');
      expect(restored.status, 'pending');
      expect(restored.payload['title'], '买菜');
    });
  });
}
