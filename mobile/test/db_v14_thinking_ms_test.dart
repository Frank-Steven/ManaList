import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// F35 收尾 / DB v14：thinking_ms 落库与迁移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Future<Database> v13Db() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE chat_messages(
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        attachments TEXT,
        status TEXT NOT NULL,
        thinking TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    return db;
  }

  test('v13 → v14：加 thinking_ms 列，旧行保留且为 NULL', () async {
    final db = await v13Db();
    await db.insert('chat_messages', {
      'id': 'm1',
      'conversation_id': 'c1',
      'role': 'assistant',
      'content': '正文',
      'status': 'done',
      'thinking': '旧思考',
      'created_at': 1,
    });

    await migrateToV14(db);

    final cols = await db.rawQuery('PRAGMA table_info(chat_messages)');
    expect(cols.any((c) => c['name'] == 'thinking_ms'), isTrue);
    final row = (await db.query('chat_messages')).single;
    expect(row['thinking'], '旧思考');
    expect(row['thinking_ms'], isNull);
    await db.close();
  });

  test('迁移幂等：重复执行不报错', () async {
    final db = await v13Db();
    await migrateToV14(db);
    await migrateToV14(db);
    final cols = await db.rawQuery('PRAGMA table_info(chat_messages)');
    expect(cols.where((c) => c['name'] == 'thinking_ms').length, 1);
    await db.close();
  });

  test('ChatMessage.thinkingMs 往返；缺列时为 null', () {
    const msg = ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      role: 'assistant',
      content: '正文',
      thinking: '思考',
      thinkingMs: 4200,
      createdAt: 1,
    );
    final row = msg.toRow();
    expect(row['thinking_ms'], 4200);
    expect(ChatMessage.fromRow(row).thinkingMs, 4200);

    final noCol = Map<String, Object?>.of(row)..remove('thinking_ms');
    expect(ChatMessage.fromRow(noCol).thinkingMs, isNull);
  });
}
