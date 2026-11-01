import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_log.dart';

/// P2-6 回归：异常必须被记录下来，且高频重复不刷屏。
void main() {
  setUp(() => AppLog.instance.clear());

  test('warn 记录一条，latest 可取到', () {
    AppLog.instance.warn('bridge.parse-file', StateError('坏文件 001.json'));
    expect(AppLog.instance.count, 1);
    expect(AppLog.instance.latest!.scope, 'bridge.parse-file');
    expect(AppLog.instance.latest!.message, contains('坏文件'));
    expect(AppLog.instance.latest!.repeats, 1);
  });

  test('同 scope 同 message 只累加计数，不新增条目', () {
    for (var i = 0; i < 5; i++) {
      AppLog.instance.warn('ai.sse-json', const FormatException('bad chunk'));
    }
    expect(AppLog.instance.count, 1);
    expect(AppLog.instance.latest!.repeats, 5);
    expect(AppLog.instance.latest!.oneLine, contains('×5'));
  });

  test('不同 message 分别记录', () {
    AppLog.instance.warn('ai.sse-json', const FormatException('a'));
    AppLog.instance.warn('ai.sse-json', const FormatException('b'));
    expect(AppLog.instance.count, 2);
  });

  test('环形缓冲不超过 capacity，且保留最新', () {
    for (var i = 0; i < AppLog.capacity + 10; i++) {
      AppLog.instance.warn('test.scope', StateError('msg-$i'));
    }
    expect(AppLog.instance.count, AppLog.capacity);
    expect(AppLog.instance.latest!.message, contains('msg-${AppLog.capacity + 9}'));
    expect(AppLog.instance.entries.first.repeats, 1);
  });

  test('clear 清空', () {
    AppLog.instance.warn('x.y', StateError('z'));
    AppLog.instance.clear();
    expect(AppLog.instance.count, 0);
    expect(AppLog.instance.latest, isNull);
  });
}
