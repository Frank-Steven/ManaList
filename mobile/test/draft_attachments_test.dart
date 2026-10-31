import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertMessage;

/// DB v9 草稿附件全链路回归（库选择 → 发送给助理 → 对话附件 bar → 发送后清空）：
/// conversations.draft_attachments 追加/去重/清空；发送时草稿随消息落
/// chat_messages.attachments 且请求里的附件经 expandAttachments 展开正文。
/// 用 sqflite_common_ffi 内存库 + mock 通道，不依赖网络与手机。

/// 捕获请求附件的 mock 通道：直接回一句文本后 done。
class _MockAssistantClient extends AssistantClient {
  _MockAssistantClient() : super.independent();

  List<ChatAttachment> capturedAttachments = const [];

  @override
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
  }) async* {
    capturedAttachments = attachments;
    yield const ChatTokenDelta('收到');
    yield const ChatDone();
  }

  @override
  void cancelActive() {}
}

ChatAttachment ref(String type, String id) => ChatAttachment(type: type, id: id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = AssistantService.instance;
  final mock = _MockAssistantClient();
  late AssistantClient realClient;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    realClient = service.client;
    service.client = mock;
    service.debugReset();
    mock.capturedAttachments = const [];
  });

  tearDown(() async {
    service.client = realClient;
    service.debugReset();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<Conversation> newConversation() => service.createConversation();

  test('草稿附件追加：按 type:id 去重，读回保持顺序', () async {
    final conv = await newConversation();
    expect(conv.draftAttachments, isEmpty);

    var drafts = await appDb.appendConversationDraftAttachments(
        conv.id, [ref('note', 'n1'), ref('file', 'f1')]);
    expect(drafts.map((a) => '${a.type}:${a.id}'), ['note:n1', 'file:f1']);

    drafts = await appDb.appendConversationDraftAttachments(
        conv.id, [ref('note', 'n1'), ref('message', 'm1')]);
    expect(drafts.map((a) => '${a.type}:${a.id}'),
        ['note:n1', 'file:f1', 'message:m1'], reason: '重复引用跳过');

    final read = await appDb.getConversationById(conv.id);
    expect(read?.draftAttachments.length, 3);
    expect(read?.draftAttachments.first.type, 'note');
  });

  test('setConversationDraftAttachments 整份覆盖（含清空）', () async {
    final conv = await newConversation();
    await appDb.appendConversationDraftAttachments(conv.id, [ref('note', 'n1')]);
    await appDb.setConversationDraftAttachments(conv.id, const []);
    expect(
        (await appDb.getConversationById(conv.id))?.draftAttachments, isEmpty);
  });

  test('发送流转：草稿随消息落 chat_messages.attachments，请求里展开正文，草稿可清空',
      () async {
    // 库实体：一条消息 + 一篇笔记 + 一个文件行（文件用二进制 mime，只展开头部）
    await insertMessage(db, 'm1', '记得买菜');
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'ch1',
      'title': '购物清单',
      'content': '牛奶 鸡蛋',
      'created_at': 1000,
      'updated_at': 1000,
    });
    await db.insert('files', {
      'id': 'f1',
      'name': '票据.pdf',
      'mime_type': 'application/pdf',
      'local_path': '/nope/f1',
      'source': 'user_upload',
      'created_at': 1000,
    });

    // 1. 库选择 → 追加为草稿附件（sendToAssistant 的落库路径）
    final conv = await newConversation();
    final drafts = await appDb.appendConversationDraftAttachments(conv.id,
        [ref('message', 'm1'), ref('note', 'n1'), ref('file', 'f1')]);

    // 2. 对话页发送：草稿随消息落库（chat_page._send 的语义），随后清空草稿
    final events =
        await service.sendTurn(conversation: conv, text: '看下这些', attachments: drafts).toList();
    await appDb.setConversationDraftAttachments(conv.id, const []);

    expect(events.last, isA<AssistantTurnDone>());

    // 用户消息带引用（仅引用，content 为 null）
    final messages = await appDb.getChatMessages(conv.id);
    final userMsg = messages.singleWhere((m) => m.role == ChatRole.user);
    expect(userMsg.attachments.map((a) => '${a.type}:${a.id}'),
        ['message:m1', 'note:n1', 'file:f1']);
    expect(userMsg.attachments.every((a) => a.content == null), isTrue);

    // 请求通道收到的是展开后的正文块（[#note:标题] 引用头，草稿与手动添加同机制）
    expect(mock.capturedAttachments, hasLength(3));
    final byType = {for (final a in mock.capturedAttachments) a.type: a};
    expect(byType['message']?.content, contains('[#message:标题m1]'));
    expect(byType['message']?.content, contains('记得买菜'));
    expect(byType['note']?.content, contains('[#note:购物清单]'));
    expect(byType['note']?.content, contains('牛奶 鸡蛋'));
    expect(byType['file']?.content, contains('[#file:票据.pdf]'));

    // 3. 发送后草稿已清空
    expect(
        (await appDb.getConversationById(conv.id))?.draftAttachments, isEmpty);
  });

  test('引用的库实体已删除时展开跳过（不阻塞回合）', () async {
    final conv = await newConversation();
    final drafts = await appDb
        .appendConversationDraftAttachments(conv.id, [ref('note', 'ghost')]);
    await service
        .sendTurn(conversation: conv, text: '看看', attachments: drafts)
        .drain();
    expect(mock.capturedAttachments, isEmpty, reason: '悬挂引用展开时跳过');
  });
}
