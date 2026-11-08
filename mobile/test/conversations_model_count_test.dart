import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v4 批次 D 对话 DAO：置顶排序/切换、待审批计数、标题+全文搜索；
/// 含批次 C 的 countConversationsByModelConfig（删除端点确认文案）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE conversations(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        model_config_id TEXT,
        draft_attachments TEXT NOT NULL DEFAULT '[]',
        pinned INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_messages(
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        attachments TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    // 本文件只用 conversation_id/status 两列做 GROUP BY，最小表即可
    await db.execute('''
      CREATE TABLE change_proposals(
        id TEXT PRIMARY KEY,
        conversation_id TEXT,
        status TEXT NOT NULL
      )
    ''');
    appDb.debugAttachDatabase(db);
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> insertConv(String id,
          {String? modelConfigId, bool pinned = false, int updatedAt = 1000}) =>
      appDb.insertConversation(Conversation(
          id: id,
          title: '对话$id',
          modelConfigId: modelConfigId,
          pinned: pinned,
          createdAt: 1000,
          updatedAt: updatedAt));

  Future<void> insertMsg(String id, String cid, String content,
          {int createdAt = 1000}) =>
      db.insert('chat_messages', {
        'id': id,
        'conversation_id': cid,
        'role': 'user',
        'content': content,
        'status': 'done',
        'created_at': createdAt,
      });

  test('countConversationsByModelConfig：按绑定关系计数，未绑定/绑定他人不计', () async {
    await insertConv('c1', modelConfigId: 'ep-a');
    await insertConv('c2', modelConfigId: 'ep-a');
    await insertConv('c3', modelConfigId: 'ep-b');
    await insertConv('c4');

    expect(await appDb.countConversationsByModelConfig('ep-a'), 2);
    expect(await appDb.countConversationsByModelConfig('ep-b'), 1);
    expect(await appDb.countConversationsByModelConfig('ep-none'), 0);
  });

  test('getConversations：置顶区在前，区内按最近更新', () async {
    await insertConv('old', updatedAt: 1000);
    await insertConv('pin-old', pinned: true, updatedAt: 2000);
    await insertConv('new', updatedAt: 3000);
    await insertConv('pin-new', pinned: true, updatedAt: 4000);

    final ids = (await appDb.getConversations()).map((c) => c.id).toList();
    expect(ids, ['pin-new', 'pin-old', 'new', 'old']);
  });

  test('setConversationPinned：置顶/取消往返', () async {
    await insertConv('c1');
    expect((await appDb.getConversations()).single.pinned, isFalse);
    await appDb.setConversationPinned('c1', true);
    expect((await appDb.getConversations()).single.pinned, isTrue);
    await appDb.setConversationPinned('c1', false);
    expect((await appDb.getConversations()).single.pinned, isFalse);
  });

  test('pendingProposalCountsByConversation：只计 pending 且挂在对话上的', () async {
    await insertConv('c1');
    await insertConv('c2');
    for (final (id, cid, status) in [
      ('p1', 'c1', 'pending'),
      ('p2', 'c1', 'pending'),
      ('p3', 'c1', 'applied'),
      ('p4', 'c2', 'pending'),
      ('p5', null, 'pending'), // 对话已删的孤儿提案不计入行副标题
    ]) {
      await db.insert('change_proposals',
          {'id': id, 'conversation_id': cid, 'status': status});
    }

    final counts = await appDb.pendingProposalCountsByConversation();
    expect(counts, {'c1': 2, 'c2': 1});
  });

  group('searchConversations（§2.3）', () {
    test('标题命中优先；正文命中带消息 id 与片段', () async {
      await insertConv('title-hit');
      await db.update('conversations', {'title': '周末采购清单'},
          where: "id = 'title-hit'");
      await insertConv('body-hit');
      await insertMsg('m1', 'body-hit', '记得买牛奶和鸡蛋');
      await insertMsg('m2', 'body-hit', '牛奶快过期了', createdAt: 2000);
      await insertConv('no-hit');

      final hits = await appDb.searchConversations('牛奶');
      expect(hits.single.conversation.id, 'body-hit');
      expect(hits.single.matchedMessageId, isNotNull);
      expect(hits.single.snippet, contains('牛奶'));

      final titleHits = await appDb.searchConversations('采购');
      expect(titleHits.single.conversation.id, 'title-hit');
      expect(titleHits.single.matchedMessageId, isNull,
          reason: '标题命中不再扫正文');
    });

    test('同一对话标题与正文都命中时只出一次（标题优先）', () async {
      await insertConv('both');
      await db.update('conversations', {'title': '牛奶相关'},
          where: "id = 'both'");
      await insertMsg('m1', 'both', '买牛奶');

      final hits = await appDb.searchConversations('牛奶');
      expect(hits.single.conversation.id, 'both');
      expect(hits.single.matchedMessageId, isNull);
    });

    test('空查询返回空表', () async {
      await insertConv('c1');
      expect(await appDb.searchConversations('  '), isEmpty);
    });
  });
}
