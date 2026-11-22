import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/assistant/chat_page.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/code_block.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// B34 回归（2026-11-22；方案 task-20 → 修订 task-29 / task-31 → 最终 task-22 rev5）。
///
/// 背景：debug 包 + 零历史新会话 + 慢速分段流式 Markdown 曾触发框架断言红屏
/// （已有真机复现）。原始首断栈为 SliverMultiBoxAdaptorElement.performRebuild/update
/// （sliver_multi_box_adaptor.dart:276 _debugVerifyChildOrder）；后续两个不同
/// GlobalKey 与 framework.dart:2170 是树乱了之后的次生现象，不能反推某个业务
/// GlobalKey 是根因。
///
/// 本轮两条修复线（都在本文件里**受控触发**并断言）：
/// 1) 活动流式区的**常量身份** ValueKey('active-streaming-turn')：零历史首回合外层
///    ListView 的 children 会从「仅活动区」变成「用户消息 + assistant 占位 + 活动区」，
///    无 key 时按位置匹配会拆掉重建这棵子树；
/// 2) 流式正文遇到**未闭合围栏**时改走上游默认 pre（_markdownView 的 useDefaultPre，
///    由 _hasUnclosedFence 行级状态机判定），围栏闭合后自动恢复既有 FencedCodeBuilder。
///    依据是 task-31 的受控对照：默认 pre 四步全过、自定义 pre 在「有代码但未闭合」
///    阶段触发 flutter_markdown builder.dart:267，并继发 sliver276；临时候选
///    （visitText 只处理空白文本）已被证伪并撤回。
///    未闭合期间的可见差异（复制按钮暂缺、块高略变）**已经用户批准**。
///
/// 边界：widget 测试通过不等价于真机首断已消除；真机 3 个全新零历史会话的
/// sliver276 / framework2170 / Duplicate GlobalKey 计数仍属功能验收范畴。

/// 可控事件脚本：每个事件都等测试显式放行后才产出，用来卡住渲染节奏。
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

// ---- B34 / task-35 诊断：A/B/C 尾部内容矩阵 + B 的单变量对照 ----
//
// 全部为**测试侧**只读复用（MarkdownBody + 既有 FencedCodeBuilder），不改任何生产文件。
// 每个用例都独立 pumpWidget（全新挂载），硬断言「无框架异常」，失败照实记录、不吞异常。
// 注意边界：这些用例**没有**复刻 chat_page 私有的 _chatMarkdownSheet(cs)，
// 因此若差异只出现在该样式表上，本矩阵覆盖不到。

/// 11 段流式输入（11 段生产用例与 B 诊断共用，保证 B 精确等于 parts[0..6]）。
const List<String> kB34StreamParts = <String>[
  '先来一段 ',
  '**加粗**',
  ' 的正文，\n\n',
  '```dart\n',
  'final a = 1;\n',
  'final b = 2;\n',
  '```\n\n',
  '- 第一项\n',
  '- 第二项\n',
  '- 第三项\n',
  '\n| 列A | 列B |\n| --- | --- |\n| 1 | 2 |',
];

/// parts[0..6]：前导段落 + 闭合 fenced code + 一个尾随空行（11 段用例第 7 段那一刻的文本）。
String b34HeadThroughFence() => kB34StreamParts.take(7).join();

/// 诊断渲染壳：与生产相同的 MarkdownBody + FencedCodeBuilder，可单变量切换。
Widget _b34MarkdownHarness(
  String data, {
  bool softLineBreak = true,
  bool selectable = false,
  bool useListView = true,
}) {
  final body = MarkdownBody(
    data: data,
    softLineBreak: softLineBreak,
    selectable: selectable,
    builders: <String, MarkdownElementBuilder>{
      'pre': FencedCodeBuilder(ColorScheme.fromSeed(seedColor: Colors.indigo)),
    },
  );
  return MaterialApp(
    home: Scaffold(
      body: useListView
          ? ListView(padding: const EdgeInsets.all(12), children: [body])
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: body,
            ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = AssistantService.instance;
  final mock = _ScriptedClient();
  late AssistantClient realClient;

  const streamingKey = ValueKey('active-streaming-turn');

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

  /// 交替「真异步」与「帧」：sqflite_ffi 的 IO 需要 runAsync，
  /// 而活动区/占位的上屏需要 pump；单纯 pumpAndSettle 会被状态秒表卡住。
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
  }

  Future<Conversation> newConversation(WidgetTester tester) async {
    late Conversation conv;
    await tester.runAsync(() async {
      conv = await service.createConversation();
    });
    return conv;
  }

  Future<List<ChatMessage>> messagesOf(WidgetTester tester, String id) async {
    late List<ChatMessage> out;
    await tester.runAsync(() async {
      out = await appDb.getChatMessages(id);
    });
    return out;
  }

  testWidgets('B34: 零历史插入用户/assistant 占位时活动流式区保持同一 element 且无框架异常',
      (tester) async {
    final conv = await newConversation(tester);
    script(const [
      ChatTokenDelta('**加粗** 开头'),
      ChatTokenDelta('**加粗** 开头，继续'),
      ChatDone(),
    ]);

    await tester.pumpWidget(MaterialApp(home: ChatPage(conversation: conv)));
    await settle(tester);
    // 零历史：还没有活动区
    expect(find.byKey(streamingKey), findsNothing);

    await send(tester, '第一句');
    await tester.pump();
    // 刚发出：_busy 已为真 → 活动区单独出现在空列表里
    expect(find.byKey(streamingKey), findsOneWidget);
    final before = tester.element(find.byKey(streamingKey));

    // TurnStarted → _reload：用户消息 + assistant 占位上屏，活动区被推到新位置
    await settle(tester);
    expect(find.byKey(streamingKey), findsOneWidget);
    // 首条消息会把会话标题改成同一文本（assistant_service.dart:486-489），
    // AppBar 标题随之同名；因此只断言「消息列表内」的正文，排除同名标题。
    final messageList = find.byWidgetPredicate(
      (w) => w is ListView && w.padding == const EdgeInsets.all(12),
      description: '消息列表（chat_page.dart:1279，padding 12）',
    );
    expect(
      find.descendant(of: messageList, matching: find.text('第一句')),
      findsOneWidget,
      reason: '历史消息里应恰好一条用户消息「第一句」（同名会话标题不算）',
    );
    final after = tester.element(find.byKey(streamingKey));

    expect(identical(before, after), isTrue,
        reason: '结构切换后活动流式区必须还是同一个 element（固定 ValueKey 的语义）');
    expect(tester.takeException(), isNull);

    // 正文增量照常往同一棵子树里长
    mock.gates[0].complete();
    await settle(tester, rounds: 4);
    expect(find.byKey(streamingKey), findsOneWidget);
    expect(identical(tester.element(find.byKey(streamingKey)), after), isTrue);
    expect(tester.takeException(), isNull);

    mock.gates[1].complete();
    await settle(tester, rounds: 4);
    expect(tester.takeException(), isNull);

    // done：流式区收尾后移除，正文留在历史消息里
    mock.gates[2].complete();
    await settle(tester);
    expect(find.byKey(streamingKey), findsNothing);
    expect(tester.takeException(), isNull);

    final msgs = await messagesOf(tester, conv.id);
    expect(msgs.length, 2, reason: '一回合应落用户消息 + assistant 消息两条');
    expect(msgs.first.role, ChatRole.user);
    expect(msgs.first.content, '第一句');
    expect(msgs.last.role, ChatRole.assistant);
    expect(msgs.last.content, contains('**加粗** 开头，继续'));
  });

  testWidgets('B34: 未闭合 fenced code→列表→表格的 11 段受控流式重建无异常且完整落库', (tester) async {
    final conv = await newConversation(tester);

    // 11 段：加粗 → 未闭合 fenced code（刻意不闭合）→ 列表 → 表格
    // 与 kB34StreamParts 同源，task-35 的 B 诊断直接取它的 parts[0..6]。
    const parts = kB34StreamParts;
    final accumulated = StringBuffer();
    final events = <ChatEvent>[];
    for (final part in parts) {
      accumulated.write(part);
      events.add(ChatTokenDelta(accumulated.toString()));
    }
    events.add(const ChatDone());
    script(events);

    await tester.pumpWidget(MaterialApp(home: ChatPage(conversation: conv)));
    await settle(tester);

    await send(tester, '给我一段结构化输出');
    await tester.pump();
    expect(find.byKey(streamingKey), findsOneWidget);

    // 逐段放行：每段之后都必须无框架异常，活动区身份保持不变
    final firstElement = tester.element(find.byKey(streamingKey));
    for (var i = 0; i < parts.length; i++) {
      mock.gates[i].complete();
      await settle(tester, rounds: 4);
      expect(tester.takeException(), isNull, reason: '第 ${i + 1} 段流式重建不应抛框架异常');
      expect(find.byKey(streamingKey), findsOneWidget,
          reason: '第 ${i + 1} 段之后活动区仍应在场');
      expect(identical(tester.element(find.byKey(streamingKey)), firstElement),
          isTrue,
          reason: '第 ${i + 1} 段之后活动区仍应是同一个 element');

      // 第 4-6 段：围栏已开、未闭合 → 走上游默认 pre（无 markdown-code-block）
      // 第 7 段：围栏闭合 → 恢复既有 FencedCodeBuilder（用户已批准的中间态到此结束）
      final customCodeBlock = find.byKey(const ValueKey('markdown-code-block'));
      if (i + 1 >= 4 && i + 1 <= 6) {
        expect(customCodeBlock, findsNothing,
            reason: '第 ${i + 1} 段围栏未闭合，应走默认 pre（不应出现自定义代码块）');
      } else if (i + 1 == 7) {
        expect(customCodeBlock, findsOneWidget,
            reason: '第 7 段围栏已闭合，应恢复 FencedCodeBuilder（常驻复制按钮那套）');
      }
    }

    mock.gates.last.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(streamingKey), findsNothing, reason: '回合结束流式区应收起');

    final msgs = await messagesOf(tester, conv.id);
    expect(msgs.length, 2);
    final assistant = msgs.last;
    expect(assistant.role, ChatRole.assistant);
    // 11 段全部落库（未闭合 fenced code 与表格都必须在正文里）
    expect(assistant.content, contains('**加粗**'));
    expect(assistant.content, contains('```dart'));
    expect(assistant.content, contains('final b = 2;'));
    expect(assistant.content, contains('- 第三项'));
    expect(assistant.content, contains('| 列A | 列B |'));
    expect(assistant.content.length, greaterThan(accumulated.length - 20),
        reason: '落库正文应与流式累计长度基本一致（允许首尾空白裁剪）');
  });

  // ---- task-35 诊断：A/B/C 尾部内容矩阵（每项独立全新挂载、硬断言）----
  //
  // 三者的前缀与 fenced code 完全相同，只改「闭合 fence 之后的尾巴」：
  //   A 无尾随内容 / B 单个空行（= 11 段用例第 7 段，parts[0..6] 精确复用）/ C 尾随段落。
  // 失败即失败，不吞异常、不降断言。

  testWidgets('B34 诊断 A: 无尾随空行（闭合 fence 即文本结束）', (tester) async {
    final data = '${kB34StreamParts.take(6).join()}```';
    expect(data.endsWith('```'), isTrue, reason: 'A 形态：文本以闭合 fence 结束');
    await tester.pumpWidget(_b34MarkdownHarness(data));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'A（无尾随内容）不得出现 builder.dart:267 / sliver276');
    expect(find.byType(MarkdownCodeBlock), findsOneWidget,
        reason: 'A：闭合 fence 仍应由 FencedCodeBuilder 接管');
  });

  testWidgets('B34 诊断 B: 单个尾随空行（parts[0..6] 精确复用）', (tester) async {
    final data = b34HeadThroughFence();
    expect(data, kB34StreamParts.take(7).join(),
        reason: 'B 必须精确等于 parts[0..6]');
    expect(data.endsWith('```\n\n'), isTrue,
        reason: 'B 形态：闭合 fence 之后恰有一个空行、没有任何后续内容');
    await tester.pumpWidget(_b34MarkdownHarness(data));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'B（单个尾随空行，即第 7 段真实形态）不得出现 builder.dart:267 / sliver276');
    expect(find.byType(MarkdownCodeBlock), findsOneWidget,
        reason: 'B：闭合 fence 仍应由 FencedCodeBuilder 接管');
  });

  testWidgets('B34 诊断 C: 尾随段落（既有 collapsible 用例形态）', (tester) async {
    final data = '${b34HeadThroughFence()}结尾段落。';
    await tester.pumpWidget(_b34MarkdownHarness(data));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'C（尾随段落）作为已知 PASS 对照组，不得出现异常');
    expect(find.byType(MarkdownCodeBlock), findsOneWidget,
        reason: 'C：闭合 fence 仍应由 FencedCodeBuilder 接管');
    expect(find.textContaining('结尾段落'), findsOneWidget);
  });

  // ---- B 的单变量对照：其余与 B 完全一致，只改一项 ----

  testWidgets('B34 诊断 B对照 softLineBreak=false（其余同 B）', (tester) async {
    await tester.pumpWidget(
        _b34MarkdownHarness(b34HeadThroughFence(), softLineBreak: false));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'softLineBreak=false 下不得出现 builder.dart:267 / sliver276');
  });

  testWidgets('B34 诊断 B对照 selectable=true（其余同 B）', (tester) async {
    await tester.pumpWidget(
        _b34MarkdownHarness(b34HeadThroughFence(), selectable: true));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'selectable=true 下不得出现 builder.dart:267 / sliver276');
  });

  testWidgets('B34 诊断 B对照 容器 SingleChildScrollView（其余同 B）', (tester) async {
    await tester.pumpWidget(
        _b34MarkdownHarness(b34HeadThroughFence(), useListView: false));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'SingleChildScrollView 容器下不得出现 builder.dart:267 / sliver276');
  });

  // ---- task-36：done 后的历史终端代码块（生产路径，不可见占位不得改变任何观感）----

  testWidgets('B34 done 历史终端代码: 单渲染/文本/复制值/横滚/44dp/无额外块高', (tester) async {
    final conv = await newConversation(tester);
    const codeText = 'final a = 1;\nfinal b = 2;';
    const finalText = '先来一段 **加粗** 的正文，\n\n```dart\n$codeText\n```';
    script(<ChatEvent>[const ChatTokenDelta(finalText), const ChatDone()]);

    // 剪贴板捕获（复用 collapsible_content_test 的 mock 口径）
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(home: ChatPage(conversation: conv)));
    await settle(tester);
    await send(tester, '给我一段代码');
    await tester.pump();
    mock.gates[0].complete();
    await settle(tester, rounds: 4);
    mock.gates[1].complete(); // done
    await settle(tester);
    expect(tester.takeException(), isNull,
        reason: 'done 后的历史渲染不得出现 builder.dart:267 / sliver276');

    // 活动区移除 + 历史只有一个代码块 + 代码文本只一份（不可见占位不携带文本）
    expect(find.byKey(streamingKey), findsNothing, reason: 'done 后活动流式区应移除');
    expect(find.byType(MarkdownCodeBlock), findsOneWidget,
        reason: '历史里应恰好一个代码块（不得双渲染）');
    expect(find.text(codeText), findsOneWidget, reason: '代码文本应只出现一份（占位节点不带文本）');

    // 横滚 + 复制按钮 ≥44dp
    final scroll = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('code-scroll')));
    expect(scroll.scrollDirection, Axis.horizontal, reason: '代码块必须横向滚动');
    final copySize = tester.getSize(find.byKey(const ValueKey('code-copy')));
    expect(copySize.width, greaterThanOrEqualTo(44), reason: '复制按钮命中宽度 ≥44dp');
    expect(copySize.height, greaterThanOrEqualTo(44), reason: '复制按钮命中高度 ≥44dp');

    // 复制值 = 原文 trimRight
    await tester.tap(find.byKey(const ValueKey('code-copy')));
    await tester.pump();
    final copied = calls.where((c) => c.method == 'Clipboard.setData');
    expect(copied, isNotEmpty, reason: '必须真的写剪贴板');
    expect((copied.last.arguments as Map)['text'], codeText,
        reason: '复制内容应等于代码原文（trimRight 后）');

    // 无额外块高：历史块高度 == 同宽度下直接渲染 MarkdownCodeBlock 的高度
    final historyHeight = tester.getSize(find.byType(MarkdownCodeBlock)).height;
    final refCs = ColorScheme.fromSeed(seedColor: Colors.indigo);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [MarkdownCodeBlock(code: codeText, colorScheme: refCs)],
        ),
      ),
    ));
    await tester.pump();
    final referenceHeight =
        tester.getSize(find.byType(MarkdownCodeBlock)).height;
    expect(historyHeight, closeTo(referenceHeight, 0.5),
        reason: '不可见占位不得引入额外块高');
  });
}
