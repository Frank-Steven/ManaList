import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// F33 / DB v13 回归：chat_messages.thinking 落库与迁移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  /// 造 v12 形态（无 thinking 列）的最小 chat_messages 表。
  Future<Database> v12Db() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
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
    return db;
  }

  test('v12 → v13：加 thinking 列，旧行保留且 thinking 为 NULL', () async {
    final db = await v12Db();
    await db.insert('chat_messages', {
      'id': 'm1',
      'conversation_id': 'c1',
      'role': 'assistant',
      'content': '旧正文',
      'status': 'done',
      'created_at': 1,
    });

    await migrateToV13(db);

    final cols = await db.rawQuery('PRAGMA table_info(chat_messages)');
    expect(cols.any((c) => c['name'] == 'thinking'), isTrue);

    final rows = await db.query('chat_messages');
    expect(rows.single['content'], '旧正文');
    expect(rows.single['thinking'], isNull);
    await db.close();
  });

  test('迁移幂等：重复执行不报错', () async {
    final db = await v12Db();
    await migrateToV13(db);
    await migrateToV13(db);
    final cols = await db.rawQuery('PRAGMA table_info(chat_messages)');
    expect(cols.where((c) => c['name'] == 'thinking').length, 1);
    await db.close();
  });

  test('ChatMessage thinking 往返；缺 thinking 列时 fromRow 为 null', () {
    const msg = ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      role: 'assistant',
      content: '正文',
      thinking: '先读任务再排序',
      createdAt: 1,
    );
    final row = msg.toRow();
    expect(row['thinking'], '先读任务再排序');

    final back = ChatMessage.fromRow(row);
    expect(back.thinking, '先读任务再排序');

    final noThinking = Map<String, Object?>.of(row)..remove('thinking');
    expect(ChatMessage.fromRow(noThinking).thinking, isNull);
  });
}
