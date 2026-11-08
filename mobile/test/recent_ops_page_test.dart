import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/crdt.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/recent_ops_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertTask;

/// 审计视图（crdt.md §5）：设置页「最近变更」只读列表，
/// actor 标注「你 / 助理·对话名 / 系统」，含 target、kind、时间。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;

  Future<void> settle(WidgetTester tester, [int times = 10]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  testWidgets('最近变更：列出 op，actor 显示你/助理·对话名/系统', (tester) async {
    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createBaseTables(db);
      appDb.debugAttachDatabase(db);
      final now = DateTime.now().millisecondsSinceEpoch;
      await appDb.insertConversation(
          Conversation(id: 'c1', title: '周报对话', createdAt: now, updatedAt: now));

      // 三种 actor 各落一条 op
      await insertTask(db, 't1', title: '买菜');
      final t = (await appDb.getTaskById('t1'))!;
      await appDb.updateTask(t.copyWith(title: '你改的')); // 默认 actor=user
      await appDb.updateTask(t.copyWith(title: '助理改的', description: () => 'd'),
          actor: OpActor.assistant('c1'));
      await appDb.recordOp(
          actor: OpActor.system,
          target: messageFieldTarget('m1', 'priority'),
          kind: OpKind.lwwSet,
          payload: {'value': 'junk'});

      await tester.pumpWidget(const MaterialApp(home: RecentOpsPage()));
      await settle(tester);

      expect(find.text('最近变更'), findsOneWidget);
      expect(find.textContaining('你 · 赋值'), findsOneWidget);
      expect(find.textContaining('助理·周报对话 · 赋值'), findsNWidgets(2),
          reason: 'title 与 description 两个字段各落一条 op');
      expect(find.textContaining('系统 · 赋值'), findsOneWidget);
      expect(find.textContaining('tasks:t1:title'), findsWidgets);
      expect(find.textContaining('messages:m1:priority'), findsOneWidget);

      await Future<void>.delayed(const Duration(milliseconds: 450));
      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('空库显示暂无记录', (tester) async {
    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createBaseTables(db);
      appDb.debugAttachDatabase(db);

      await tester.pumpWidget(const MaterialApp(home: RecentOpsPage()));
      await settle(tester);
      expect(find.text('暂无记录。'), findsOneWidget);

      appDb.debugDetachDatabase();
      await db.close();
    });
  });
}
