import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/assistant/conversations_page.dart';
import 'package:msgrepo_mobile/ui/library/library_page.dart';
import 'package:msgrepo_mobile/ui/tasks/tasks_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// B44：三根页面的 FloatingActionButton 统一 heroTag:null。
///
/// 背景（task-83/88/89 真机日志）：HomeShell 的页面栈可同时持有库页 / 任务页 /
/// 会话页，三个 FAB 都用默认 heroTag 时会触发「Multiple heroes share the same tag」
/// 警告；它们之间没有任何共享元素转场需求，因此显式 null（禁用 Hero）而不是给
/// 各自字符串 tag —— 后者会凭空造出慢速 Hero 动画。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;
  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    AppUiState.instance.setLibrarySection(AppUiState.librarySectionMessages);
    // 会话页用可控 loader，避免真实网络
    ConversationsPageState.debugLoaderOverride =
        () async => const ConversationsLoadResult(conversations: <Conversation>[]);
  });

  tearDown(() async {
    ConversationsPageState.debugLoaderOverride = null;
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  /// 装载页面并取回**页面上真实的** FAB 对象（不是新建的替身）。
  Future<FloatingActionButton> pumpAndGetFab(
      WidgetTester tester, Widget page, String label) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await settle(tester);
    final finder = find.byType(FloatingActionButton);
    expect(finder, findsOneWidget, reason: 'label 页应有且仅有 1 个 FAB');
    return tester.widget<FloatingActionButton>(finder);
  }

  testWidgets('库页 / 任务页 / 会话页的 FAB 都是 heroTag:null', (tester) async {
    final libraryFab = await pumpAndGetFab(tester, const LibraryPage(), '库');
    expect(libraryFab.heroTag, isNull, reason: '库页 FAB 必须显式 heroTag:null');

    final tasksFab = await pumpAndGetFab(tester, const TasksPage(), '任务');
    expect(tasksFab.heroTag, isNull, reason: '任务页 FAB 必须显式 heroTag:null');

    final conversationsFab =
        await pumpAndGetFab(tester, const ConversationsPage(), '会话');
    expect(conversationsFab.heroTag, isNull,
        reason: '会话页 FAB 必须显式 heroTag:null');
  });

  testWidgets('三页 FAB 的 tag 全为 null —— 同栈并存时不存在「重复默认 tag」', (tester) async {
    final tags = <Object?>[
      (await pumpAndGetFab(tester, const LibraryPage(), '库')).heroTag,
      (await pumpAndGetFab(tester, const TasksPage(), '任务')).heroTag,
      (await pumpAndGetFab(tester, const ConversationsPage(), '会话')).heroTag,
    ];
    // 默认 heroTag 是 _DefaultHeroTag 实例，三页同栈会「同 tag 多个 Hero」。
    // 全部显式 null 后不存在任何非空 tag，也就不可能重复。
    expect(tags.where((t) => t != null), isEmpty,
        reason: '不允许任何页面保留非空 heroTag（会造出无意义 Hero 动画或重复告警）');
    expect(tags.every((t) => t == null), isTrue,
        reason: '三页 FAB 都必须 heroTag:null');
  });
}
