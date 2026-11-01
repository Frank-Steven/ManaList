import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/fold_markers.dart';

/// U14 回归：只剥离结尾的「(N条新消息)」，不动其他内容。
void main() {
  test('半角括号后缀被去掉', () {
    expect(stripFoldMarkers('没有op的美好世界(2条新消息)'), '没有op的美好世界');
    expect(stripFoldMarkers('这tm是哪个骑士(10条新消息)'), '这tm是哪个骑士');
  });

  test('全角括号同样处理', () {
    expect(stripFoldMarkers('南邮军事爱好者同盟（3条新消息）'), '南邮军事爱好者同盟');
  });

  test('括号内外的空格被容错', () {
    expect(stripFoldMarkers('测试群 ( 5 条新消息 ) '), '测试群');
  });

  test('没有标记时原样返回（含正文里的 [N条] 前缀）', () {
    expect(stripFoldMarkers('张三'), '张三');
    expect(stripFoldMarkers('[5条] 张三: 明天开会'), '[5条] 张三: 明天开会');
  });

  test('标记不在结尾时不动', () {
    expect(stripFoldMarkers('(2条新消息)在后面还有字'),
        '(2条新消息)在后面还有字');
  });

  test('整条只有标记时保留原文（不展示为空）', () {
    expect(stripFoldMarkers('(2条新消息)'), '(2条新消息)');
  });

  test('连续多层标记一起剥掉（D02 放宽后）', () {
    expect(stripFoldMarkers('群(1条新消息)(2条新消息)'), '群');
    expect(stripFoldMarkers('群(1条新消息) (2条新消息)'), '群');
  });

  test('空串安全', () {
    expect(stripFoldMarkers(''), '');
    expect(stripFoldMarkers('   '), '');
  });
  // D02（2026-10-21）：QQ 群名常带「(100条以上新消息)」「(99+条新消息)」「(3条未读)」
  test('「以上」变体被剥掉', () {
    expect(stripFoldMarkers('南邮战雷同好会(100条以上新消息)'), '南邮战雷同好会');
    expect(stripFoldMarkers('柒世纪_南邮东方射爆会【…】(5条以上新消息)'), '柒世纪_南邮东方射爆会【…】');
  });

  test('「99+」变体被剥掉', () {
    expect(stripFoldMarkers('没有op的美好世界(99+条新消息)'), '没有op的美好世界');
    expect(stripFoldMarkers('测试群 ( 99+ 条新消息 ) '), '测试群');
  });

  test('「未读」变体被剥掉', () {
    expect(stripFoldMarkers('群A(3条未读)'), '群A');
    expect(stripFoldMarkers('群B（12条未读消息）'), '群B');
  });

  test('只有标记时仍保留原文（不会显示为空）', () {
    expect(stripFoldMarkers('(100条以上新消息)'), '(100条以上新消息)');
  });

  test('真实括号内容不被误剥', () {
    expect(stripFoldMarkers('会议纪要(2026年10月)'), '会议纪要(2026年10月)');
    expect(stripFoldMarkers('报销单(3张)'), '报销单(3张)');
  });
}
