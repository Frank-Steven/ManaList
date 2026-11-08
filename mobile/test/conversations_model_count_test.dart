import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v4 批次 C：删除端点前确认文案要列出绑定它的对话数
///（assistant-v4-ui §5.1，删除后这些对话回退默认模型）。
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
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    appDb.debugAttachDatabase(db);
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> insertConv(String id, String? modelConfigId) =>
      db.insert('conversations', {
        'id': id,
        'title': '对话$id',
        'model_config_id': modelConfigId,
        'created_at': 1000,
        'updated_at': 1000,
      });

  test('countConversationsByModelConfig：按绑定关系计数，未绑定/绑定他人不计', () async {
    await insertConv('c1', 'ep-a');
    await insertConv('c2', 'ep-a');
    await insertConv('c3', 'ep-b');
    await insertConv('c4', null);

    expect(await appDb.countConversationsByModelConfig('ep-a'), 2);
    expect(await appDb.countConversationsByModelConfig('ep-b'), 1);
    expect(await appDb.countConversationsByModelConfig('ep-none'), 0);
  });
}
