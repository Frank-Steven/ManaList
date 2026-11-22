import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/crdt.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/assistant_logo.dart';
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
      await appDb.insertConversation(Conversation(
          id: 'c1', title: '周报对话', createdAt: now, updatedAt: now));

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

      // F45（task-45）：actor 图标 —— user=person_outline、system=settings_suggest_outlined、
      // assistant=新双星；隔离 widget 补验，不代表真机覆盖。
      expect(find.byIcon(Icons.person_outline), findsOneWidget,
          reason: 'user 行仍是 person_outline');
      expect(find.byIcon(Icons.settings_suggest_outlined), findsOneWidget,
          reason: 'system 行仍是 settings_suggest_outlined');

      // 两条 assistant op（title/description）→ 两个新双星
      expect(find.byType(AssistantLogo), findsNWidgets(2),
          reason: 'assistant 行用新双星，数量应与 assistant op 条数一致');
      final assistantTile = find
          .ancestor(
            of: find.textContaining('助理·周报对话 · 赋值').first,
            matching: find.byType(ListTile),
          )
          .first;
      final logoInAssistantTile = find.descendant(
          of: assistantTile, matching: find.byType(AssistantLogo));
      expect(logoInAssistantTile, findsOneWidget,
          reason: 'assistant 行的 leading 必须是新双星');
      final logo = tester.widget<AssistantLogo>(logoInAssistantTile);
      expect(logo.size, 24, reason: 'recent_ops 行图标 24px');
      final cs =
          Theme.of(tester.element(find.byType(RecentOpsPage))).colorScheme;
      expect(logo.color, cs.onSurfaceVariant,
          reason: 'assistant 行图标颜色应跟随 onSurfaceVariant');

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
