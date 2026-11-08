import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/input_bar.dart';

/// `/` 快捷指令面板（assistant-v4-ui §3.6）：前缀匹配规则。
void main() {
  test('非 / 开头 → 无面板', () {
    expect(matchingSlashCommands(''), isEmpty);
    expect(matchingSlashCommands('你好'), isEmpty);
    expect(matchingSlashCommands('a/b'), isEmpty);
  });

  test('裸 / → 全部指令', () {
    expect(matchingSlashCommands('/'), kSlashCommands.keys.toList());
  });

  test('前缀过滤', () {
    expect(matchingSlashCommands('/整'), ['整理收件箱']);
    expect(matchingSlashCommands('/总'), ['总结']);
    expect(matchingSlashCommands('/不存在'), isEmpty);
  });

  test('每个指令都有非空模板', () {
    for (final t in kSlashCommands.values) {
      expect(t.trim().isNotEmpty, isTrue);
    }
  });
}
