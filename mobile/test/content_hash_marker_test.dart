import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// content_hash 与锚点 marker 剥离（design-v3-details §1.4）：
/// 参与去重/哈希的文本必须先剥离 marker——strip 内建于 computeContentHash，
/// 通知采集入库、导入、手动添加、编辑保存重算全部走这一个函数，天然一致。
const anchorId = '123e4567-e89b-42d3-a456-426614174000';
const anchorId2 = 'abcdef01-2345-4678-89ab-cdef01234567';

void main() {
  sqfliteFfiInit();

  group('computeContentHash 先 strip 再哈希', () {
    test('含 marker 的消息与原始通知文本哈希一致', () {
      const body = '记得买菜';
      const withMarker = '记得买菜⟦task:$anchorId⟧';
      expect(computeContentHash('pkg', '标题', withMarker, 1000),
          computeContentHash('pkg', '标题', body, 1000));
    });

    test('多个 marker 全部剥离', () {
      const withMarkers = '前文⟦task:$anchorId⟧中⟦task:$anchorId2⟧后文';
      expect(computeContentHash('pkg', 't', withMarkers, 1),
          computeContentHash('pkg', 't', '前文中后文', 1));
    });

    test('strip 不做空白折叠：追加式 marker 留下的空格参与哈希', () {
      expect(computeContentHash('pkg', 't', 'a ⟦task:$anchorId⟧ b', 1),
          computeContentHash('pkg', 't', 'a  b', 1));
    });

    test('其余分量仍然参与哈希', () {
      final base = computeContentHash('pkg', 't', 'b', 1);
      expect(computeContentHash('pkg2', 't', 'b', 1), isNot(base));
      expect(computeContentHash('pkg', 't2', 'b', 1), isNot(base));
      expect(computeContentHash('pkg', 't', 'b', 2), isNot(base));
    });
  });

  group('编辑保存路径重算 content_hash（§1.4-2）', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE messages(
          id TEXT PRIMARY KEY,
          package_name TEXT NOT NULL,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          posted_at INTEGER NOT NULL,
          content_hash TEXT NOT NULL UNIQUE,
          edited_at INTEGER
        )
      ''');
      AppDatabase.instance.debugAttachDatabase(db);
    });

    tearDown(() async {
      AppDatabase.instance.debugDetachDatabase();
      await db.close();
    });

    Future<void> insertMessage(String id, String body) =>
        db.insert('messages', {
          'id': id,
          'package_name': 'com.test',
          'title': '标题$id',
          'body': body,
          'posted_at': 2000,
          'content_hash':
              computeContentHash('com.test', '标题$id', body, 2000),
        });

    test('编辑正文（含 marker）后重算：与剥离后文本的哈希一致', () async {
      await insertMessage('m1', '原始正文');
      final originalHash = (await db.query('messages')).single['content_hash'];

      // 用户编辑：正文里带上了锚点 marker
      await AppDatabase.instance
          .updateMessageBody('m1', '原始正文⟦task:$anchorId⟧补充');

      final row = (await db.query('messages')).single;
      expect(row['edited_at'], isNotNull);
      expect(
          row['content_hash'],
          computeContentHash(
              'com.test', '标题m1', '原始正文⟦task:$anchorId⟧补充', 2000));
      expect(
          row['content_hash'],
          computeContentHash('com.test', '标题m1', '原始正文补充', 2000),
          reason: '哈希输入是剥离 marker 后的文本');
      expect(row['content_hash'], isNot(originalHash),
          reason: '正文真的变了，哈希必须跟上');
    });

    test('仅 marker 变化的编辑：哈希与原始通知一致（再送达仍判重）', () async {
      await insertMessage('m1', '记得买菜');
      final originalHash = (await db.query('messages')).single['content_hash'];

      await AppDatabase.instance
          .updateMessageBody('m1', '记得买菜⟦task:$anchorId⟧');

      final row = (await db.query('messages')).single;
      expect(row['content_hash'], originalHash,
          reason: 'strip 后文本与采集原文相同 → 同一通知再次送达仍命中去重');
    });
  });
}
