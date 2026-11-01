import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/library/folder_tree.dart';

/// 文件夹树构建（库·文件区树形总览 / 树形移动选择器共用）：
/// 路径列表（'a/b/c'）→ 嵌套节点；乱序输入、去重、祖先缺失自动补齐。
void main() {
  test('嵌套路径按层级挂树', () {
    final roots = buildFolderTree(['工作/截图/2026', '工作/文档', '生活']);
    expect(roots.map((n) => n.name), ['工作', '生活']);
    final work = roots.first;
    expect(work.path, '工作');
    expect(work.children.map((n) => n.name), ['截图', '文档']);
    final shots = work.children.first;
    expect(shots.path, '工作/截图');
    expect(shots.children.single.path, '工作/截图/2026');
  });

  test('乱序与缺失祖先：自动补齐中间层', () {
    final roots = buildFolderTree(['a/b/c', 'a/b']);
    expect(roots.single.name, 'a');
    expect(roots.single.children.single.path, 'a/b');
    expect(roots.single.children.single.children.single.path, 'a/b/c');
  });

  test('重复路径只建一个节点；空路径忽略', () {
    final roots = buildFolderTree(['x', '', 'x', 'x/y', 'x/y']);
    expect(roots, hasLength(1));
    expect(roots.single.children, hasLength(1));
  });

  test('空列表返回空树', () {
    expect(buildFolderTree(const []), isEmpty);
  });
}
