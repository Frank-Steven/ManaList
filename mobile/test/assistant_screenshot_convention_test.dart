import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/screenshot_convention.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// F03 Step3/4 请求级回归：截图整理约定必须**进入模型请求的系统前言**，
/// 且**不污染用户消息正文**（气泡与落库 content 保持原文/默认指令）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const toolSpec = 'TOOL-SPEC-PLACEHOLDER';

  const imageAtt = ChatAttachment(
    type: 'file',
    id: 'f-img',
    content: '[#file:shot.png]（image/png）\n[图像已内联：64×64 PNG]',
    mimeType: 'image/png',
    dataBase64: 'AAAA',
  );
  const noteAtt = ChatAttachment(
    type: 'note',
    id: 'n1',
    content: '[#note:随手记]\n正文',
  );

  /// 把 buildRemoteMessages 的结果拍平成文本（content 可能是 String 或 parts 列表）。
  List<String> textsOf(List<Map<String, dynamic>> out) {
    final texts = <String>[];
    for (final m in out) {
      final c = m['content'];
      if (c is String) {
        texts.add(c);
      } else if (c is List) {
        for (final part in c) {
          if (part is Map && part['type'] == 'text') {
            texts.add('${part['text']}');
          }
        }
      }
    }
    return texts;
  }

  group('systemPreambleWithConvention（唯一拼接点）', () {
    test('有截图：带标题段落，关键四点齐全，且只出现一次', () {
      final p = systemPreambleWithConvention(toolSpec, hasScreenshots: true);
      expect(p, startsWith('[系统说明]\n$toolSpec'), reason: '工具说明书仍在最前');
      expect(p, contains('[截图整理约定]'));
      expect(p, contains('每张截图单独成条'));
      expect(p, contains('task.create'));
      expect(p, contains('note.create'));
      expect(p, contains('不跨图合并'));
      expect('[截图整理约定]'.allMatches(p).length, 1, reason: '不重复拼约定');
    });

    test('无截图：前言与旧行为完全一致（不含约定）', () {
      final p = systemPreambleWithConvention(toolSpec, hasScreenshots: false);
      expect(p, '[系统说明]\n$toolSpec');
      expect(p, isNot(contains('截图整理约定')));
      expect(p, isNot(contains('每张截图单独成条')));
    });
  });

  group('请求级：约定进模型、用户正文不被污染', () {
    List<ChatMessageModel> messagesWith({required bool hasScreenshots}) => [
          ChatMessageModel(
            role: ChatRole.user,
            content: systemPreambleWithConvention(toolSpec,
                hasScreenshots: hasScreenshots),
          ),
          const ChatMessageModel(role: ChatRole.user, content: '帮我整理这些截图。'),
        ];

    test('有图 + vision：首条上下文后紧跟的系统前言含约定', () {
      final out = buildRemoteMessages(
        messagesWith(hasScreenshots: true),
        attachments: const [imageAtt, noteAtt],
        vision: true,
      );
      final texts = textsOf(out);
      expect(texts.any((t) => t.contains('[截图整理约定]')), isTrue,
          reason: '约定必须真的进了请求');
      expect(texts.any((t) => t.contains('不跨图合并')), isTrue);
      // 图片确实内联（content parts 路径）
      expect(out.first['content'], isA<List>());
    });

    test('有图但非 vision：图像不内联，约定照样注入（意图仍成立）', () {
      final out = buildRemoteMessages(
        messagesWith(hasScreenshots: true),
        attachments: const [imageAtt],
        vision: false,
      );
      expect(out.first['content'], isA<String>(), reason: '非 vision 不发 content parts');
      expect(out.first['content'] as String, contains('[#file:shot.png]'));
      expect(textsOf(out).any((t) => t.contains('[截图整理约定]')), isTrue);
    });

    test('无图（只有笔记附件）：请求里完全不出现约定', () {
      final out = buildRemoteMessages(
        messagesWith(hasScreenshots: false),
        attachments: const [noteAtt],
        vision: false,
      );
      final texts = textsOf(out);
      expect(texts.any((t) => t.contains('截图整理约定')), isFalse);
      expect(texts.any((t) => t.contains('每张截图单独成条')), isFalse);
    });

    test('用户消息正文保持原文：约定不落进用户气泡/落库 content', () {
      final out = buildRemoteMessages(
        messagesWith(hasScreenshots: true),
        attachments: const [imageAtt],
        vision: true,
      );
      final userMessage = out.last;
      expect(userMessage['content'], '帮我整理这些截图。');
      expect(userMessage['content'], isNot(contains('每张截图单独成条')));
      expect(userMessage['content'], isNot(contains('[截图整理约定]')));
      // 约定只出现在系统前言那一条里
      final conventionCount =
          textsOf(out).where((t) => t.contains('[截图整理约定]')).length;
      expect(conventionCount, 1);
    });
  });

  group('attachmentsContainScreenshot（真 DB，与 vision 无关）', () {
    late Database db;
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
    });

    tearDown(() async {
      appDb.debugDetachDatabase();
      await db.close();
    });

    Future<void> insertFile(String id, String mime, String name) => db.insert(
          'files',
          {
            'id': id,
            'name': name,
            'mime_type': mime,
            'size': 1,
            'local_path': '/tmp/$name',
            'source': 'test',
            'created_at': 1,
          },
        );

    test('图片文件 → true；笔记/文本文件/空表 → false', () async {
      await insertFile('f-img', 'image/png', 'shot.png');
      await insertFile('f-txt', 'text/plain', 'notes.txt');

      expect(
          await service.attachmentsContainScreenshot(
              const [ChatAttachment(type: 'file', id: 'f-img')]),
          isTrue);
      expect(
          await service.attachmentsContainScreenshot(const [
            ChatAttachment(type: 'note', id: 'n1'),
            ChatAttachment(type: 'file', id: 'f-txt'),
          ]),
          isFalse);
      expect(await service.attachmentsContainScreenshot(const []), isFalse);
      // 不存在的文件引用不 panic
      expect(
          await service.attachmentsContainScreenshot(
              const [ChatAttachment(type: 'file', id: 'missing')]),
          isFalse);
    });
  });
}
