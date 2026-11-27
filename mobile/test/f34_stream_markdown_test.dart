import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/assistant/chat_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// F34 专项：**真实 ChatPage 流式区**的 Markdown 渲染（生产渲染逻辑不改、不复制）。
///
/// 与既有 chat_page_streaming_test.dart 分工：那边验证结构稳定性（element 恒定 /
/// 无框架异常 / 11 段落库），本文件验证「屏幕上真的是 Markdown 而不是裸文本」——
/// 断言取自真实 RichText / Table 结构，并区分「DB 原文含 Markdown 语法」与
/// 「屏幕不裸显 ** 或表格分隔行」。
class _ScriptedClient extends AssistantClient {
  _ScriptedClient() : super.independent();

  final List<Completer<void>> gates = [];
  final List<ChatEvent> events = [];

  @override
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
    String? reasoning,
  }) async* {
    for (var i = 0; i < events.length; i++) {
      await gates[i].future;
      yield events[i];
    }
  }

  @override
  void cancelActive() {}
}

/// 屏幕上任一 RichText 里是否存在「粗体 + 含 [text]」的 span。
bool hasBoldSpan(WidgetTester tester, String text) {
  var found = false;
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      final bold = span.style?.fontWeight == FontWeight.bold ||
          (span.style?.fontWeight?.value ?? 0) > FontWeight.w500.value;
      if (bold && (span.text ?? '').contains(text)) found = true;
      span.children?.forEach(walk);
    }
  }

  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rt.text);
  }
  return found;
}

/// 屏幕上是否裸显了 Markdown 标记（粗体星号 / 表格分隔行 / fence）。
bool screenShowsRawMarkdown(WidgetTester tester) {
  return find.textContaining('**').evaluate().isNotEmpty ||
      find.textContaining('| --- |').evaluate().isNotEmpty ||
      find.textContaining('```').evaluate().isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = AssistantService.instance;
  final mock = _ScriptedClient();
  late AssistantClient realClient;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    realClient = service.client;
    service.client = mock;
    service.debugReset();
  });

  tearDown(() async {
    service.client = realClient;
    service.debugReset();
    appDb.debugDetachDatabase();
    await db.close();
  });

  void script(List<ChatEvent> evs) {
    mock.events
      ..clear()
      ..addAll(evs);
    mock.gates
      ..clear()
      ..addAll(
          List<Completer<void>>.generate(evs.length, (_) => Completer<void>()));
  }

  Future<void> settle(WidgetTester tester,
      {int rounds = 8, int ms = 25}) async {
    for (var i = 0; i < rounds; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump(Duration(milliseconds: ms));
    }
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
  }

  Future<Conversation> newConversation(WidgetTester tester) async {
    late Conversation conv;
    await tester.runAsync(() async {
      conv = await service.createConversation();
    });
    return conv;
  }

  Future<String> lastAssistantContent(
      WidgetTester tester, String conversationId) async {
    late String out;
    await tester.runAsync(() async {
      final msgs = await appDb.getChatMessages(conversationId);
      out = msgs.lastWhere((m) => m.role == ChatRole.assistant).content;
    });
    return out;
  }

  testWidgets('F34: 流式中间态「**加粗**」渲染为粗体 span，屏幕不裸显，DB 原文仍含语法', (tester) async {
    final conv = await newConversation(tester);
    script(const [
      ChatTokenDelta('先来一段 **加粗**'),
      ChatTokenDelta(' 的正文，流式仍在进行'),
      ChatDone(),
    ]);

    await tester.pumpWidget(MaterialApp(home: ChatPage(conversation: conv)));
    await settle(tester);
    await send(tester, '测试加粗');
    await settle(tester);

    mock.gates[0].complete();
    await settle(tester, rounds: 6);

    expect(hasBoldSpan(tester, '加粗'), isTrue,
        reason: '流式区必须按 Markdown 渲染粗体 span，而不是裸文本 **加粗**');
    expect(screenShowsRawMarkdown(tester), isFalse, reason: '屏幕不得裸显 ** 标记');
    expect(tester.takeException(), isNull);

    mock.gates[1].complete();
    await settle(tester, rounds: 6);
    expect(screenShowsRawMarkdown(tester), isFalse, reason: '增量到达后仍不裸显');
    expect(tester.takeException(), isNull);

    mock.gates[2].complete();
    await settle(tester);

    // ChatDone 后：历史气泡同样走 Markdown（chat_page:1453 → _markdownView:1482）
    expect(hasBoldSpan(tester, '加粗'), isTrue,
        reason: '落库后历史气泡也必须保持 Markdown 粗体');
    expect(screenShowsRawMarkdown(tester), isFalse);
    expect(tester.takeException(), isNull);

    // 区分「DB 原文含语法」与「屏幕裸显」：DB 有 **，屏幕没有
    final persisted = await lastAssistantContent(tester, conv.id);
    expect(persisted, contains('**加粗**'),
        reason: 'DB 保存 Markdown 原文（本条即「含语法」证据）');
    expect(screenShowsRawMarkdown(tester), isFalse,
        reason: '屏幕渲染结果与 DB 原文不同：不裸显');
  });

  testWidgets('F34: 未闭合 fenced code 中间态不抛框架异常，闭合后按代码块渲染', (tester) async {
    final conv = await newConversation(tester);
    script(const [
      ChatTokenDelta('代码：\n\n```dart\n'),
      ChatTokenDelta('final a = 1;\n'),
      ChatTokenDelta('final b = 2;\n```\n'),
      ChatDone(),
    ]);

    await tester.pumpWidget(MaterialApp(home: ChatPage(conversation: conv)));
    await settle(tester);
    await send(tester, '测试代码块');
    await settle(tester);

    // 打开 fence 但未闭合的中间态
    mock.gates[0].complete();
    await settle(tester, rounds: 6);
    expect(tester.takeException(), isNull, reason: '未闭合 fence 渲染不得抛框架异常');
    expect(find.textContaining('```'), findsNothing, reason: '屏幕不裸显 fence 标记');

    mock.gates[1].complete();
    await settle(tester, rounds: 6);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('final a = 1;'), findsWidgets,
        reason: '代码块内容应已渲染');

    mock.gates[2].complete();
    await settle(tester, rounds: 6);
    mock.gates[3].complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('final b = 2;'), findsWidgets);
    expect(screenShowsRawMarkdown(tester), isFalse);
  });

  testWidgets('F34: 列表与表格增量到达时渲染出真实 Markdown 结构（列表项 / Table）', (tester) async {
    final conv = await newConversation(tester);
    script(const [
      ChatTokenDelta('- 第一项\n'),
      ChatTokenDelta('- 第二项\n'),
      ChatTokenDelta('\n| 列A | 列B |\n| --- | --- |\n| 1 | 2 |'),
      ChatDone(),
    ]);

    await tester.pumpWidget(MaterialApp(home: ChatPage(conversation: conv)));
    await settle(tester);
    await send(tester, '测试列表表格');
    await settle(tester);

    mock.gates[0].complete();
    await settle(tester, rounds: 5);
    mock.gates[1].complete();
    await settle(tester, rounds: 5);
    expect(find.textContaining('第一项'), findsWidgets, reason: '列表项 1 已渲染');
    expect(find.textContaining('第二项'), findsWidgets, reason: '列表项 2 已渲染');

    mock.gates[2].complete();
    await settle(tester, rounds: 6);
    expect(find.byType(Table), findsWidgets,
        reason: '增量到达的表格必须是真实 Table 结构，而不是裸 | --- | 文本');
    expect(screenShowsRawMarkdown(tester), isFalse, reason: '不裸显表格分隔行');

    mock.gates[3].complete();
    await settle(tester);
    expect(find.byType(Table), findsWidgets, reason: '落库后历史仍渲染 Table');
    expect(tester.takeException(), isNull);
  });
}
