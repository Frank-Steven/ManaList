import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/attachment_store.dart';

/// P3-2 回归：附件必须复制进应用目录、同内容去重、旧路径不可用时能如实报告。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('msgrepo-att-');
    AttachmentStore.debugDirOverride = tmp;
  });

  tearDown(() {
    AttachmentStore.debugDirOverride = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('导入字节 → 落盘到应用目录，路径与大小正确', () async {
    final att = await AttachmentStore.instance.importBytes(
      Uint8List.fromList([1, 2, 3, 4]),
      kind: Attachment.kindFile,
      label: 'a.bin',
      fileName: 'a.bin',
    );
    expect(att.bytes, 4);
    expect(att.access.type, AttachmentAccess.typeLocalPath);
    final f = File(att.access.value);
    expect(f.existsSync(), isTrue);
    expect(f.parent.path, tmp.path, reason: '必须落在应用目录里');
    expect(att.access.value.endsWith('.bin'), isTrue);
  });

  test('同样内容重复导入 → 复用同一文件（sha256 去重）', () async {
    final a = await AttachmentStore.instance
        .importBytes(Uint8List.fromList([9, 9, 9]), kind: Attachment.kindImage);
    final b = await AttachmentStore.instance
        .importBytes(Uint8List.fromList([9, 9, 9]), kind: Attachment.kindImage);
    expect(a.access.value, b.access.value);
    expect(tmp.listSync().whereType<File>().length, 1);
  });

  test('从磁盘路径导入（模拟 image_picker 的缓存文件）', () async {
    final src = File('${tmp.path}/src.jpg')..writeAsBytesSync([7, 7, 7, 7, 7]);
    final att = await AttachmentStore.instance
        .importPath(src.path, kind: Attachment.kindImage, label: 'src.jpg');
    expect(att, isNotNull);
    expect(att!.bytes, 5);
    expect(att.access.value, isNot(src.path), reason: '必须是复制品');
    expect(File(att.access.value).existsSync(), isTrue);
  });

  test('原文件不存在时返回 null，不抛异常', () async {
    final att = await AttachmentStore.instance.importPath(
      '${tmp.path}/nope.jpg',
      kind: Attachment.kindImage,
    );
    expect(att, isNull);
  });

  test('resolve：文件在则返回，不在则返回 null（旧数据场景）', () async {
    final att = await AttachmentStore.instance
        .importBytes(Uint8List.fromList([1]), kind: Attachment.kindFile);
    expect(AttachmentStore.instance.resolve(att), isNotNull);
    File(att.access.value).deleteSync();
    expect(AttachmentStore.instance.resolve(att), isNull);
  });

  test('只删仓库内的文件，不碰外部路径', () async {
    final other = Directory.systemTemp.createTempSync('msgrepo-outside-');
    addTearDown(() => other.deleteSync(recursive: true));
    final outside = File('${other.path}/outside.txt')..writeAsBytesSync([1]);
    final att = Attachment(
      id: 'x',
      kind: Attachment.kindFile,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: outside.path,
      ),
    );
    await AttachmentStore.instance.deleteQuietly(att);
    expect(outside.existsSync(), isTrue, reason: '外部文件不应被删');
  });

  test('Attachment JSON 往返保留 bytes；旧数据没有该字段也能读', () {
    const withBytes = Attachment(
      id: 'a',
      kind: Attachment.kindFile,
      label: 'x.bin',
      bytes: 123,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: '/tmp/x.bin',
      ),
    );
    expect(Attachment.fromJson(withBytes.toJson()).bytes, 123);

    final legacy = Attachment.fromJson(<String, dynamic>{
      'id': 'b',
      'kind': 'file',
      'access': <String, dynamic>{'type': 'local_path', 'value': '/tmp/y'},
    });
    expect(legacy.bytes, isNull);
  });
}
