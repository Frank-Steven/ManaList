import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/image_encoder.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 多模态（图像输入）支持回归：
/// - buildRemoteMessages：远程通道附件上下文组装（纯文本 vs content parts）；
/// - encodeInlineImage：dart:ui 现场生成 PNG，验证缩放与不缩放两条路径；
/// - expandAttachments：vision / 非 vision 下图片附件的展开结果（真 DB）。

/// 现场生成 w×h 的纯色 PNG 字节（不依赖测试资产文件）。
Future<Uint8List> makePngBytes(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final img = await recorder.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

const pngMagic = [0x89, 0x50, 0x4E, 0x47];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('buildRemoteMessages', () {
    test('tool 角色折叠为带前缀的 user 消息；无附件不前置上下文', () {
      final out = buildRemoteMessages(const [
        ChatMessageModel(role: ChatRole.user, content: 'hi'),
        ChatMessageModel(role: ChatRole.tool, content: '结果'),
      ]);
      expect(out, [
        {'role': 'user', 'content': 'hi'},
        {'role': 'user', 'content': '[工具执行结果]\n结果'},
      ]);
    });

    test('文本附件 → 前置纯文本上下文消息', () {
      final out = buildRemoteMessages(
        const [ChatMessageModel(role: ChatRole.user, content: '总结一下')],
        attachments: const [
          ChatAttachment(type: 'note', id: 'n1', content: '[#note:清单]\n牛奶'),
        ],
      );
      expect(out.length, 2);
      expect(out.first['role'], 'user');
      expect(out.first['content'], isA<String>());
      expect(out.first['content'] as String, contains('[#note:清单]'));
    });

    test('vision + 图片附件 → content parts（text + image_url data URL）', () {
      final out = buildRemoteMessages(
        const [ChatMessageModel(role: ChatRole.user, content: '看图')],
        vision: true,
        attachments: const [
          ChatAttachment(
            type: 'file',
            id: 'f1',
            content: '[#file:照片.png]',
            mimeType: 'image/png',
            dataBase64: 'aGVsbG8=',
          ),
        ],
      );
      final content = out.first['content'] as List;
      expect(content, hasLength(2));
      final textPart = content[0] as Map;
      expect(textPart['type'], 'text');
      expect(textPart['text'] as String, contains('[#file:照片.png]'));
      final imgPart = content[1] as Map;
      expect(imgPart['type'], 'image_url');
      expect((imgPart['image_url'] as Map)['url'],
          'data:image/png;base64,aGVsbG8=');
    });

    test('非 vision：图片附件只给文本，绝不附带图像（避免端点报错）', () {
      final out = buildRemoteMessages(
        const [ChatMessageModel(role: ChatRole.user, content: '看图')],
        attachments: const [
          ChatAttachment(
            type: 'file',
            id: 'f1',
            content: '[#file:照片.png]（未附带图像内容）',
            mimeType: 'image/png',
            dataBase64: 'aGVsbG8=',
          ),
        ],
      );
      expect(out.first['content'], isA<String>());
      expect(out.first['content'] as String, contains('未附带图像内容'));
    });
  });

  group('encodeInlineImage', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('img_enc_test');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('超过最大边 → 等比缩放到 1024，输出 PNG', () async {
      final f = File('${dir.path}/big.png');
      await f.writeAsBytes(await makePngBytes(2000, 100));
      final r = await encodeInlineImage(f.path);
      expect(r, isNotNull);
      expect(r!.width, 1024);
      expect(r.height, 51, reason: '100 × 1024/2000 ≈ 51');
      expect(base64Decode(r.dataBase64).sublist(0, 4), pngMagic);
    });

    test('小图不缩放', () async {
      final f = File('${dir.path}/small.png');
      await f.writeAsBytes(await makePngBytes(100, 50));
      final r = await encodeInlineImage(f.path);
      expect(r, isNotNull);
      expect(r!.width, 100);
      expect(r.height, 50);
    });

    test('非图片字节 → null（调用方退化为仅文字头）', () async {
      final f = File('${dir.path}/bad.png');
      await f.writeAsString('not an image');
      expect(await encodeInlineImage(f.path), isNull);
    });

    test('文件不存在 → null', () async {
      expect(await encodeInlineImage('${dir.path}/missing.png'), isNull);
    });
  });

  group('expandAttachments（图片附件）', () {
    late Database db;
    late Directory dir;
    final appDb = AppDatabase.instance;
    final service = AssistantService.instance;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE files(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          mime_type TEXT,
          size INTEGER,
          local_path TEXT NOT NULL,
          source TEXT NOT NULL,
          folder TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL
        )
      ''');
      appDb.debugAttachDatabase(db);
      dir = await Directory.systemTemp.createTemp('expand_img_test');
    });

    tearDown(() async {
      appDb.debugDetachDatabase();
      await db.close();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<void> insertImageFile(String id) async {
      final png = await makePngBytes(64, 64);
      final f = File('${dir.path}/照片.png');
      await f.writeAsBytes(png);
      await db.insert('files', {
        'id': id,
        'name': '照片.png',
        'mime_type': 'image/png',
        'size': png.length,
        'local_path': f.path,
        'source': 'test',
        'created_at': 1,
      });
    }

    test('vision：图片附件内联缩放后的 PNG', () async {
      await insertImageFile('f1');
      final out = await service.expandAttachments(
          [const ChatAttachment(type: 'file', id: 'f1')],
          visionCapable: true);
      expect(out, hasLength(1));
      final a = out.single;
      expect(a.content, contains('[#file:照片.png]'));
      expect(a.content, contains('图像已内联'));
      expect(a.mimeType, 'image/png', reason: 'dataBase64 固定是 PNG 重编码产物');
      expect(a.dataBase64, isNotNull);
      expect(base64Decode(a.dataBase64!).sublist(0, 4), pngMagic);
    });

    test('非 vision：只声明不附带图像内容', () async {
      await insertImageFile('f1');
      final out = await service
          .expandAttachments([const ChatAttachment(type: 'file', id: 'f1')]);
      final a = out.single;
      expect(a.content, contains('未附带图像内容'));
      expect(a.dataBase64, isNull);
      expect(a.mimeType, isNull);
    });

    test('文本附件展开不受 vision 参数影响', () async {
      final f = File('${dir.path}/notes.txt');
      await f.writeAsString('正文内容');
      await db.insert('files', {
        'id': 'f2',
        'name': 'notes.txt',
        'mime_type': 'text/plain',
        'size': 8,
        'local_path': f.path,
        'source': 'test',
        'created_at': 1,
      });
      final out = await service.expandAttachments(
          [const ChatAttachment(type: 'file', id: 'f2')],
          visionCapable: true);
      final a = out.single;
      expect(a.content, contains('正文内容'));
      expect(a.dataBase64, isNull);
    });
  });
}
