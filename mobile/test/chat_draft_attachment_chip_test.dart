import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/library_file.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/attachment_cards.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/input_bar.dart';

/// F03 附件预览子项（真机 FAIL）：草稿图片附件 chip 原先只有 onDeleted，
/// 点按毫无反应。修复后：图片 chip 点按 → 复用附件卡片的全屏查看器
/// （Dialog + InteractiveViewer）；非图片 chip 仍不可点；删除按钮不变。
void main() {
  // 1x1 PNG（真实文件，避免 Image.file 解码报错刷日志）
  const kPng1x1 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

  late Directory tmp;
  late LibraryFile imageFile;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('f03_chip_');
    final p = File('${tmp.path}/shot.png')
      ..writeAsBytesSync(base64Decode(kPng1x1));
    imageFile = LibraryFile(
      id: 'f-img',
      name: 'shot.png',
      mimeType: 'image/png',
      size: p.lengthSync(),
      localPath: p.path,
      source: 'album',
      createdAt: 0,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const imageAtt = ChatAttachment(type: ChatAttachmentType.file, id: 'a-img');
  const noteAtt = ChatAttachment(type: ChatAttachmentType.note, id: 'a-note');

  Widget harness({
    required List<ChatAttachment> atts,
    required ValueChanged<ChatAttachment> onRemove,
  }) {
    final metas = <String, AttachmentMeta>{
      'a-img': AttachmentMeta(
          title: 'shot.png', icon: Icons.image_outlined, file: imageFile),
      'a-note': const AttachmentMeta(
          title: '随手记', icon: Icons.sticky_note_2_outlined),
    };
    return MaterialApp(
      home: Scaffold(
        body: ChatInputBar(
          controller: TextEditingController(),
          busy: false,
          attachments: atts,
          metaOf: (a) => metas[a.id],
          onRemoveAttachment: onRemove,
          onAddAttachments: () {},
          onPickScreenshots: () {},
          onSend: () {},
          onCancel: () {},
        ),
      ),
    );
  }

  testWidgets('图片草稿 chip 点按 → 打开全屏预览（可缩放查看器）', (tester) async {
    await tester.pumpWidget(harness(atts: const [imageAtt], onRemove: (_) {}));
    expect(find.byType(InputChip), findsOneWidget);

    await tester.tap(find.text('shot.png'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: '复用附件卡片的查看器，支持双指缩放');
  });

  testWidgets('非图片草稿 chip 点按不弹预览（保持原交互）', (tester) async {
    await tester.pumpWidget(harness(atts: const [noteAtt], onRemove: (_) {}));

    await tester.tap(find.text('随手记'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    final chip = tester.widget<InputChip>(find.byType(InputChip));
    expect(chip.onPressed, isNull, reason: '笔记/消息/非图片文件仍不可点开');
  });

  testWidgets('删除入口与批量附件条保持可用', (tester) async {
    ChatAttachment? removed;
    await tester.pumpWidget(harness(
        atts: const [imageAtt, noteAtt], onRemove: (a) => removed = a));

    expect(find.byType(InputChip), findsNWidgets(2),
        reason: '多附件一行并排（批量上限逻辑在挑选阶段，不在 chip 渲染）');
    final first = tester.widget<InputChip>(find.byType(InputChip).first);
    expect(first.onDeleted, isNotNull, reason: '删除按钮必须保留');
    first.onDeleted!();
    expect(removed?.id, 'a-img');
  });

  testWidgets('有图片草稿时输入框提示「可留空直接发送」', (tester) async {
    await tester.pumpWidget(harness(atts: const [imageAtt], onRemove: (_) {}));
    expect(find.text('可留空：直接发送这些截图'), findsOneWidget);
  });

  testWidgets('无图片草稿时保持原文案', (tester) async {
    await tester.pumpWidget(harness(atts: const [noteAtt], onRemove: (_) {}));
    expect(find.text('和助理说点什么…'), findsOneWidget);
  });
}
