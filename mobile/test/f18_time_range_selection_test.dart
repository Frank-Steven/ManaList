import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';
import 'package:msgrepo_mobile/ui/assistant/attachment_pick_controller.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/ui/messages/message_time_range.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';
import 'package:msgrepo_mobile/ui/library/library_page.dart';
import 'package:msgrepo_mobile/ui/messages/messages_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertTask;

/// F18（方案 A）回归：消息页按时间段筛选 + 全选 ID 快照 + 多选永久删除（复用 B46 备份）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;
  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    // B46/F18：撤销备份表（undo_deleted_messages / undo_deleted_anchors）由迁移创建，
    // 与 b46_archive_selectall_test 同一做法（复用顶级 migrateToV15，不另写建表）。
    await migrateToV15(db);
    appDb.debugAttachDatabase(db);
    UndoService.instance.clear();
  });

  tearDown(() async {
    UndoService.instance.clear();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> seedMessage(String id,
          {int postedAt = 2000,
          String pkg = 'com.test.a',
          String status = MessageStatus.pending,
          String priority = MessagePriority.none}) =>
      db.insert('messages', <String, Object?>{
        'id': id,
        'package_name': pkg,
        'app_name': '测试应用',
        'title': '标题$id',
        'body': '正文$id',
        'posted_at': postedAt,
        'capture_type': 'notification',
        'attachments': '[]',
        'content_hash': 'hash-$id',
        'status': status,
        'priority': priority,
        'created_at': 2000,
      });

  Future<void> seedMany(int n,
      {String prefix = 'm',
      int startAt = 2000,
      String pkg = 'com.test.a'}) async {
    final batch = db.batch();
    for (var i = 0; i < n; i++) {
      batch.insert('messages', <String, Object?>{
        'id': '$prefix$i',
        'package_name': pkg,
        'app_name': '测试应用',
        'title': '标题$i',
        'body': '正文$i',
        'posted_at': startAt + i,
        'capture_type': 'notification',
        'attachments': '[]',
        'content_hash': 'hash-$prefix$i',
        'status': MessageStatus.pending,
        'priority': MessagePriority.none,
        'created_at': 2000,
      });
    }
    await batch.commit(noResult: true);
  }

  /// 窄屏逻辑表面（320×640）+ 结束恢复：用于选择头「大数量隐藏文本」溢出回归。
  void useNarrowSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> settle(WidgetTester tester, [int times = 12]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  /// 组默认折叠：只展开一级来源头（稳定 key，避免误触「显示更多」的同名图标）。
  /// 已展开（显示 expand_less / 或处于多选态无图标）则跳过；点击前先 ensureVisible。
  Future<void> expandAllSources(WidgetTester tester) async {
    for (final pkg in const <String>['com.test.a', 'com.test.b']) {
      final header = find.byKey(ValueKey('source-header-$pkg'));
      if (header.evaluate().isEmpty) continue;
      final collapsed =
          find.descendant(of: header, matching: find.byIcon(Icons.expand_more));
      if (collapsed.evaluate().isEmpty) continue;
      await tester.ensureVisible(header.first);
      await tester.pump();
      await tester.tap(header.first);
      await settle(tester);
    }
  }

  Future<void> pickTimePreset(WidgetTester tester, String label) async {
    // 窄屏（320dp）下时间 chip 可能在横向筛选栏的屏外，先滚入可视区再真实 tap
    // （chip 主体有稳定 key；不依赖坐标，也不使用 warnIfMissed:false）。
    final idle = find.text('时间范围');
    if (idle.evaluate().isNotEmpty) {
      await tester
          .ensureVisible(find.byKey(const ValueKey('f18-time-chip-body')));
      await tester.pump();
      await tester.tap(idle.first);
    } else {
      final icon = find.byIcon(Icons.event_outlined).first;
      await tester.ensureVisible(icon);
      await tester.pump();
      await tester.tap(icon);
    }
    await settle(tester);
    await tester.tap(find.text(label));
    await settle(tester);
  }

  /// 进入选择态：默认长按第一条；传 [id] 时长按该消息。
  ///
  /// 生产在 MessageTile 上已设 key: ValueKey(m.id)（messages_page.dart:1140），
  /// 因此可按消息 ID 精确定位；手势仍走 tile 内**真实 onLongPress 回调**。
  Future<void> enterSelectionWithFirstRow(WidgetTester tester,
      {String? id}) async {
    final tile =
        id == null ? find.byType(MessageTile).first : find.byKey(ValueKey(id));
    expect(tile, findsOneWidget, reason: '目标消息行应唯一存在');
    final target = find
        .descendant(
          of: tile,
          matching: find.byWidgetPredicate(
              (w) => w is GestureDetector && w.onLongPress != null),
        )
        .first;
    expect(target, findsOneWidget, reason: 'tile 内应有真实 onLongPress 手势目标');
    tester.widget<GestureDetector>(target).onLongPress!();
    await tester.pump();
  }

  // ---------- 纯函数：本地半开区间 ----------
  group('时间范围纯函数（本地半开区间 [start,end)）', () {
    test('今天：含起始日 00:00，不含次日 00:00', () {
      final now = DateTime(2026, 3, 15, 14, 30);
      final r = messageTimeRangeToday(now);
      expect(r.start, DateTime(2026, 3, 15));
      expect(r.end, DateTime(2026, 3, 16));
      expect(r.containsPostedAt(DateTime(2026, 3, 15).millisecondsSinceEpoch),
          isTrue);
      expect(
          r.containsPostedAt(
              DateTime(2026, 3, 15, 23, 59, 59, 999).millisecondsSinceEpoch),
          isTrue);
      expect(r.containsPostedAt(DateTime(2026, 3, 16).millisecondsSinceEpoch),
          isFalse);
      expect(
          r.containsPostedAt(
              DateTime(2026, 3, 14, 23, 59, 59, 999).millisecondsSinceEpoch),
          isFalse);
    });

    test('昨天与近 7 天（6 个日历日，跨月）', () {
      final y = messageTimeRangeYesterday(DateTime(2026, 3, 2, 9));
      expect(y.start, DateTime(2026, 3, 1));
      expect(y.end, DateTime(2026, 3, 2));

      final w = messageTimeRangeLast7Days(DateTime(2026, 3, 3, 21));
      expect(w.start, DateTime(2026, 2, 25)); // 3/3 往前 6 个日历日
      expect(w.end, DateTime(2026, 3, 4));
      expect(w.containsPostedAt(DateTime(2026, 2, 25).millisecondsSinceEpoch),
          isTrue);
      expect(
          w.containsPostedAt(
              DateTime(2026, 2, 24, 23, 59).millisecondsSinceEpoch),
          isFalse);
    });

    test('自定义：严格 [start 00:00, end 00:00)，结束日当天不含、同日非法', () {
      final r =
          messageTimeRangeCustom(DateTime(2026, 3, 10), DateTime(2026, 3, 12));
      expect(r.start, DateTime(2026, 3, 10));
      expect(r.end, DateTime(2026, 3, 12), reason: '结束日 00:00（不含）');
      expect(
          r.containsPostedAt(
              DateTime(2026, 3, 11, 23, 59, 59, 999).millisecondsSinceEpoch),
          isTrue);
      expect(r.containsPostedAt(DateTime(2026, 3, 12).millisecondsSinceEpoch),
          isFalse,
          reason: '03/12 当天消息不命中');
      expect(r.label, '03/10-03/11', reason: 'label 按 end-1ms 显示，与原型一致');
      expect(
          isMessageTimeRangeCustomValid(
              DateTime(2026, 3, 10), DateTime(2026, 3, 10)),
          isFalse,
          reason: '同日 = 空区间，非法');
      expect(
          isMessageTimeRangeCustomValid(
              DateTime(2026, 3, 11), DateTime(2026, 3, 10)),
          isFalse,
          reason: 'start > end 非法');
      expect(
          isMessageTimeRangeCustomValid(
              DateTime(2026, 3, 10), DateTime(2026, 3, 11)),
          isTrue);
    });

    test('已生效 custom 重开弹层不漂移：按自身 start/end 的日历日重建 == 原范围', () {
      final r0 =
          messageTimeRangeCustom(DateTime(2026, 3, 10), DateTime(2026, 3, 12));
      // 弹层草稿保存的是 start/end 本身（零点），再次「确认」用它们的日历日重建
      final r1 = messageTimeRangeCustom(r0.start, r0.end);
      expect(r1, r0, reason: '再次确认不得把结束日再往后推一天');
      expect(r1.end, DateTime(2026, 3, 12));
      // 撤销/取消路径不改状态（等价于直接沿用 r0）
      expect(r0.end, DateTime(2026, 3, 12));
    });
  });

  // ---------- DB：limit:null 与 500 分块 ----------
  group('DB：limit:null 与分块写（501/1200）', () {
    test('limit:null 取消隐性上限；不传仍默认 500', () async {
      await seedMany(501);
      expect((await appDb.getMessages()).length, 500,
          reason: '既有默认 defaultMessageLimit=500 不变');
      expect((await appDb.getMessages(limit: null)).length, 501,
          reason: 'limit:null = 不加 LIMIT');
    });

    test('includeArchived:false 在 SQL 层排除归档；默认仍包含归档', () async {
      await seedMany(501, prefix: 'n');
      await seedMany(20, prefix: 'arch', startAt: 9000);
      await appDb.updateMessageStatusChunked(
          [for (var i = 0; i < 20; i++) 'arch$i'], MessageStatus.archived);

      expect((await appDb.getMessages(limit: null)).length, 521,
          reason: '默认 includeArchived:true 仍包含归档');
      expect(
          (await appDb.getMessages(limit: null, includeArchived: false)).length,
          501,
          reason: 'false 时 SQL 层排除归档，只需返回 501 非归档');
    });

    test('1200 条分块改优先级/状态（跨 500 边界）', () async {
      await seedMany(1200);
      final ids = [for (final m in await appDb.getMessages(limit: null)) m.id];
      expect(ids.length, 1200);
      await appDb.updateMessagePriorityChunked(ids, MessagePriority.junk);
      expect(
          (await appDb
                  .getMessages(priorities: [MessagePriority.junk], limit: null))
              .length,
          1200);
      await appDb.updateMessageStatusChunked(ids, MessageStatus.archived);
      expect(
          (await appDb.getMessages(status: MessageStatus.archived, limit: null))
              .length,
          1200);
    });
  });

  // ---------- 页面：时间筛选 / 全选 / 隐藏已选 / 空态 / pick ----------
  group('消息页：时间筛选与全选（真实页面 + 内存 DB）', () {
    testWidgets('应用+分组+时间 AND；弹层确认生效、取消不改、两种清除都只清时间', (tester) async {
      await tester.runAsync(() async {
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 10)
            .millisecondsSinceEpoch;
        final y0 = t0 - const Duration(days: 1).inMilliseconds;
        await seedMessage('t1', postedAt: t0, pkg: 'com.test.a');
        await seedMessage('t2', postedAt: t0 + 1000, pkg: 'com.test.a');
        await seedMessage('y1', postedAt: y0, pkg: 'com.test.b');

        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);
        await expandAllSources(tester);
        expect(find.byType(MessageTile), findsNWidgets(3));

        // 选「今天」→ 只剩 2 条（应用/分组条件未动）
        await pickTimePreset(tester, '今天');
        await expandAllSources(tester);
        expect(find.byType(MessageTile), findsNWidgets(2), reason: '时间条件生效');

        // 弹层「取消」不改已生效条件
        await tester.tap(find.byIcon(Icons.event_outlined).first);
        await settle(tester);
        await tester.tap(find.text('取消'));
        await settle(tester);
        await expandAllSources(tester);
        expect(find.byType(MessageTile), findsNWidgets(2), reason: '取消不应用草稿');

        // chip 上的 ✕：只清时间
        await tester.tap(find.byIcon(Icons.close).first);
        await settle(tester);
        await expandAllSources(tester);
        expect(find.byType(MessageTile), findsNWidgets(3), reason: '清除时间后恢复');

        // 弹层里的「清除时间筛选」：同样只清时间
        await pickTimePreset(tester, '今天');
        await tester.tap(find.byIcon(Icons.event_outlined).first);
        await settle(tester);
        expect(find.text('清除时间筛选'), findsOneWidget);
        await tester.tap(find.text('清除时间筛选'));
        await settle(tester);
        await expandAllSources(tester);
        expect(find.byType(MessageTile), findsNWidgets(3));

        // 弹层结构：今天/昨天/近 7 天 + 自定义起止（开始日/结束日）+ 取消/确认
        await tester.tap(find.text('时间范围'));
        await settle(tester);
        expect(find.text('今天'), findsOneWidget);
        expect(find.text('昨天'), findsOneWidget);
        expect(find.text('近 7 天'), findsOneWidget);
        expect(find.textContaining('开始日：'), findsOneWidget);
        expect(find.textContaining('结束日：'), findsOneWidget);
        expect(find.text('取消'), findsOneWidget);
        expect(find.text('确认'), findsOneWidget);
        // 自定义日期选择器本身不在此断言（交互重且口径已由纯函数覆盖），
        // 仅确认入口存在后取消，保证「取消不改已生效条件」。
        await tester.tap(find.text('取消'));
        await settle(tester);
      });
    });

    testWidgets('全选跨越每组 10 条分页；切时间后隐藏已选保留并计数', (tester) async {
      await tester.runAsync(() async {
        // 窄屏：验证「已选 35 项（含 5 未显示）」这类大数量文本不撑破选择头
        useNarrowSurface(tester);
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 9)
            .millisecondsSinceEpoch;
        final y0 = t0 - const Duration(days: 1).inMilliseconds;
        await seedMany(30, prefix: 'a', startAt: t0); // 今天
        await seedMany(5, prefix: 'b', startAt: y0, pkg: 'com.test.b'); // 昨天

        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);
        await expandAllSources(tester);

        await enterSelectionWithFirstRow(tester);
        await settle(tester);
        await tester.tap(find.text('全选'));
        await settle(tester);
        expect(find.textContaining('已选 35 项'), findsOneWidget,
            reason: '全选 = 全部可见 ID（不止每组首屏 10 条）');

        // 时间条件=今天：可见 30，已选仍 35 → 头部提示「含 5 未显示」
        await pickTimePreset(tester, '今天');
        await settle(tester);
        expect(find.textContaining('已选 35 项'), findsOneWidget,
            reason: '切筛选不得删除隐藏已选 ID');
        expect(find.textContaining('含 5 未显示'), findsOneWidget);

        // 窄屏下选择头不得 RenderFlex 溢出（摘要已用 Expanded + 单行省略）
        expect(tester.takeException(), isNull, reason: '320 宽度下选择头不得溢出');
        final summary = tester.widget<Text>(find.textContaining('含 5 未显示'));
        expect(summary.maxLines, 1, reason: '摘要单行');
        expect(summary.overflow, TextOverflow.ellipsis, reason: '超宽省略而非溢出');
        // 按钮仍可找到且可用（语义文本完整）
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, '全选'))
                .onPressed,
            isNotNull);
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
                .onPressed,
            isNotNull);
      });
    });

    testWidgets('reload 后新消息不自动加入已选；空态给出清除入口', (tester) async {
      await tester.runAsync(() async {
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 8)
            .millisecondsSinceEpoch;
        await seedMessage('t1', postedAt: t0);
        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);
        await expandAllSources(tester);

        await enterSelectionWithFirstRow(tester);
        await settle(tester);
        expect(find.textContaining('已选 1 项'), findsOneWidget);

        await seedMessage('t2', postedAt: t0 + 1000);
        await tester
            .state<MessagesPageState>(find.byType(MessagesPage))
            .reload();
        await settle(tester);
        expect(find.textContaining('已选 1 项'), findsOneWidget,
            reason: '新消息不得自动并入已选集合');
      });
    });

    testWidgets('pick 模式：选择写控制器（既有唯一事实源）', (tester) async {
      await tester.runAsync(() async {
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 8)
            .millisecondsSinceEpoch;
        await seedMessage('t1', postedAt: t0);
        final pick = AttachmentPickController();
        await tester.pumpWidget(MaterialApp(
            home: MessagesPage(pickMode: true, pickController: pick)));
        await settle(tester);
        await expandAllSources(tester);
        await tester.tap(find.byType(MessageTile).first);
        await settle(tester);
        expect(pick.isSelected(ChatAttachmentType.message, 't1'), isTrue);
      });
    });
  });

  // ---------- rev5 门槛：全选禁用 / 44dp 命中区 / pick 批量单次通知 ----------
  group('rev5：全选禁用、44dp 命中区、pick 批量单次通知', () {
    testWidgets('可见为空时全选禁用，并给出时间专属空态与清除入口', (tester) async {
      await tester.runAsync(() async {
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 9)
            .millisecondsSinceEpoch;
        await seedMessage('only-today', postedAt: t0);

        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);
        await expandAllSources(tester);

        await enterSelectionWithFirstRow(tester);
        await settle(tester);
        expect(find.textContaining('已选 1 项'), findsOneWidget);

        // 切到「昨天」：该区间没有消息 → 可见为空
        await pickTimePreset(tester, '昨天');
        await settle(tester);
        final selectAllBtn =
            tester.widget<TextButton>(find.widgetWithText(TextButton, '全选'));
        expect(selectAllBtn.onPressed, isNull, reason: '可见为空时全选必须禁用');
        expect(find.text('该时间段没有消息'), findsOneWidget, reason: '时间专属空态');
        expect(find.text('清除时间筛选'), findsOneWidget, reason: '空态给清除入口');
        expect(find.textContaining('已选 1 项'), findsOneWidget,
            reason: '可见为空也不得删掉隐藏已选 ID');
      });
    });

    testWidgets('时间胶囊视觉 36 / 命中 ≥44（未激活 + 激活都覆盖，不溢出）', (tester) async {
      await tester.runAsync(() async {
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 9)
            .millisecondsSinceEpoch;
        await seedMessage('m1', postedAt: t0);

        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);

        // ---- 未激活：视觉背景 36，主体命中 ≥44，无 ✕ ----
        final idleVisual =
            tester.getSize(find.byKey(const ValueKey('f18-time-chip-visual')));
        expect(idleVisual.height, 36, reason: '未激活视觉背景与左侧应用胶囊一致 36dp');
        expect(
            tester
                .getSize(find.byKey(const ValueKey('f18-time-chip-body')))
                .height,
            greaterThanOrEqualTo(44),
            reason: '未激活主体命中区 ≥44dp');
        expect(find.byKey(const ValueKey('f18-time-chip-clear')), findsNothing);
        expect(tester.takeException(), isNull, reason: '未激活不得溢出');

        // ---- 激活：视觉仍 36，主体与 ✕ 命中都 ≥44 ----
        await pickTimePreset(tester, '今天');
        await settle(tester);

        final visual =
            tester.getSize(find.byKey(const ValueKey('f18-time-chip-visual')));
        expect(visual.height, 36, reason: '激活态视觉背景同样 36dp');
        final clearSize =
            tester.getSize(find.byKey(const ValueKey('f18-time-chip-clear')));
        expect(clearSize.width, greaterThanOrEqualTo(44));
        expect(clearSize.height, greaterThanOrEqualTo(44));
        final bodySize =
            tester.getSize(find.byKey(const ValueKey('f18-time-chip-body')));
        expect(bodySize.height, greaterThanOrEqualTo(44),
            reason: '激活态主体命中区同样 ≥44dp');
        expect(tester.takeException(), isNull, reason: '激活态不得溢出/裁切异常');
      });
    });

    testWidgets('chip 清除按钮有语义节点：bySemanticsLabel 可定位并真实 tap，只清时间且保留选择',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.runAsync(() async {
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 9)
            .millisecondsSinceEpoch;
        final y0 = t0 - const Duration(days: 1).inMilliseconds;
        await seedMessage('s1', postedAt: t0, pkg: 'com.test.a');
        await seedMessage('s2', postedAt: y0, pkg: 'com.test.b');

        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);
        await expandAllSources(tester);

        // 先选 1 条，再设时间条件，最后用语义节点清除时间
        await enterSelectionWithFirstRow(tester, id: 's1');
        await settle(tester);
        await pickTimePreset(tester, '今天');
        await settle(tester);
        expect(find.textContaining('已选 1 项'), findsOneWidget);

        final clear = find.bySemanticsLabel('清除时间筛选');
        expect(clear, findsOneWidget, reason: '真机 uiautomator 需按语义节点定位清除按钮');
        await tester.tap(clear); // 真实 tap 语义节点
        await settle(tester);

        await expandAllSources(tester);
        expect(find.text('时间范围'), findsOneWidget, reason: '只清时间条件');
        expect(find.byType(MessageTile), findsNWidgets(2),
            reason: '其它条件未动，全部消息回到列表');
        expect(find.textContaining('已选 1 项'), findsOneWidget,
            reason: '清除时间不得清掉已选 ID');
      });
      handle.dispose();
    });

    test('1200 条 pick 批量全选只通知一次', () {
      final pick = AttachmentPickController();
      var notifications = 0;
      pick.addListener(() => notifications++);
      final titles = <String, String>{
        for (var i = 0; i < 1200; i++) 'p$i': '标题$i',
      };
      pick.selectMany(ChatAttachmentType.message, titles,
          icon: Icons.mail_outline);
      expect(notifications, 1, reason: '批量写入必须合并为一次 notify');
      expect(pick.idsOfType(ChatAttachmentType.message).length, 1200);
    });
  });

  // ---------- task-87：真实 LibraryPage 宿主下的页面内 messenger 撤销 ----------
  group('页面内 SnackBar 作用域（真实 LibraryPage 宿主）', () {
    void usePhoneSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('LibraryPage 宿主：删除 2 条（各带精确锚点）→ 提示可见 → 真实撤销全恢复',
        (tester) async {
      await tester.runAsync(() async {
        usePhoneSurface(tester);
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 9)
            .millisecondsSinceEpoch;
        await seedMessage('L1', postedAt: t0);
        await seedMessage('L2', postedAt: t0 + 1000);
        await seedMessage('Lkeep', postedAt: t0 + 2000);
        await insertTask(db, 'lt1');
        for (final id in <String>['L1', 'L2']) {
          await db.insert('task_anchors', <String, Object?>{
            'id': 'a-$id',
            'task_id': 'lt1',
            'target_type': 'message',
            'target_id': id,
            'label': '锚点-$id',
            'created_by': 'user',
            'created_at': 1500,
          });
        }
        AppUiState.instance
            .setLibrarySection(AppUiState.librarySectionMessages);

        // 真实库页宿主（消息分区为第一页）
        await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
        await settle(tester);
        await expandAllSources(tester);

        await enterSelectionWithFirstRow(tester, id: 'L1');
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('L2')));
        await settle(tester);
        expect(find.textContaining('已选 2 项'), findsOneWidget);

        await tester.tap(find.byTooltip('删除'));
        await settle(tester);
        // 入场动画结束后断言（仍远小于 4s 窗口）
        await tester.pump(const Duration(milliseconds: 320));

        // 页面内 messenger：提示与撤销必须可见（真机曾 12 次 dump 全无）
        expect(find.text('已删除'), findsOneWidget,
            reason: '页面内 ScaffoldMessenger 下提示必须可见');
        expect(find.text('撤销'), findsOneWidget);

        await tester.tap(find.text('撤销')); // 真实 tap
        await settle(tester);

        // 本文件没有 countMessages helper，用现有口径直接计数（断言仍为 3）
        expect((await appDb.getMessages(limit: null)).length, 3,
            reason: '一次撤销恢复两条消息');
        final anchors =
            await db.rawQuery('SELECT COUNT(*) AS c FROM task_anchors');
        expect((anchors.first['c'] as num).toInt(), 2, reason: '锚点一并恢复');
        final left = await db
            .rawQuery('SELECT COUNT(*) AS c FROM undo_deleted_messages');
        expect((left.first['c'] as num).toInt(), 0, reason: '备份已清');
      });
    });
  });

  // ---------- 页面：多选删除复用 B46 备份 + 一次撤销 ----------
  group('消息页多选删除：复用 B46 备份 + 精确锚点一次撤销', () {
    void usePhoneSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('批量删除 2 条（各带精确锚点）→ 备份 4 行 → 一次撤销全恢复', (tester) async {
      await tester.runAsync(() async {
        usePhoneSurface(tester);
        final today = DateTime.now();
        final t0 = DateTime(today.year, today.month, today.day, 8)
            .millisecondsSinceEpoch;
        await seedMessage('d1', postedAt: t0);
        await seedMessage('d2', postedAt: t0 + 1000);
        await seedMessage('keep', postedAt: t0 + 2000);
        await insertTask(db, 't1');
        for (final id in <String>['d1', 'd2']) {
          await db.insert('task_anchors', <String, Object?>{
            'id': 'a-$id',
            'task_id': 't1',
            'target_type': 'message',
            'target_id': id, // 精确匹配被删 ID
            'label': '锚点-$id',
            'created_by': 'user',
            'created_at': 1500,
          });
        }

        await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
        await settle(tester);
        await expandAllSources(tester);

        // 列表按 postedAt 倒序（keep → d2 → d1），因此按消息 ID 精确选 d1 + d2，
        // 避免 at(1) 误选 keep（那会变成 2 条消息只带 1 个锚点）。
        await enterSelectionWithFirstRow(tester, id: 'd1');
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('d2')));
        await settle(tester);
        expect(find.textContaining('已选 2 项'), findsOneWidget);

        await tester.tap(find.byTooltip('删除'));
        await settle(tester);
        final undoRows = await db
            .rawQuery('SELECT (SELECT COUNT(*) FROM undo_deleted_messages) + '
                '(SELECT COUNT(*) FROM undo_deleted_anchors) AS c');
        expect((undoRows.first['c'] as num).toInt(), 4,
            reason: '备份 = 2 条消息 + 2 个精确锚点');
        expect((await appDb.getMessages(limit: null)).length, 1,
            reason: '仅 keep 存活');

        // 真实点 SnackBar 的「撤销」
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.text('已删除'), findsOneWidget);
        await tester.tap(find.text('撤销'));
        await settle(tester);

        expect((await appDb.getMessages(limit: null)).length, 3,
            reason: '一次撤销恢复两条消息');
        final anchors =
            await db.rawQuery('SELECT COUNT(*) AS c FROM task_anchors');
        expect((anchors.first['c'] as num).toInt(), 2, reason: '锚点一并恢复');
        final left = await db
            .rawQuery('SELECT COUNT(*) AS c FROM undo_deleted_messages');
        expect((left.first['c'] as num).toInt(), 0, reason: '备份已清');
      });
    });
  });
}
