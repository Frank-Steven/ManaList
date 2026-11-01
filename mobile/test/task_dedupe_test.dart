import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/task_dedupe.dart';

/// 防重复任务（消息↔任务多对多）回归：归一化与「同一件事」判定的边界。
///
/// 设计原则：宁可漏合并，也不误合并 —— 只做机械归一化 + 精确标题 + 时间一致。
void main() {
  Task task({
    String id = 't1',
    String title = '交周报',
    int? startAt,
    String status = TaskStatus.active,
    int createdAt = 1000,
  }) =>
      Task(
        id: id,
        title: title,
        kind: TaskKind.point,
        startAt: startAt,
        status: status,
        createdAt: createdAt,
        updatedAt: createdAt,
      );

  final t0 = DateTime(2026, 10, 21, 12, 0).millisecondsSinceEpoch;

  group('normalizeTaskTitle', () {
    test('全角转半角 + 去空白', () {
      expect(normalizeTaskTitle('ＡＢ　Ｃ'), 'abc');
      expect(normalizeTaskTitle(' 交 周 报 '), '交周报');
    });

    test('去中英文标点与符号', () {
      expect(normalizeTaskTitle('交周报！'), '交周报');
      expect(normalizeTaskTitle('交周报（第3周）'), '交周报第3周');
      expect(normalizeTaskTitle('交周报 - 周五'), '交周报周五');
      expect(normalizeTaskTitle('「例会」'), '例会');
    });

    test('去 emoji 与装饰符号', () {
      expect(normalizeTaskTitle('交周报🔥'), '交周报');
      expect(normalizeTaskTitle('✅ 例会 ⏰'), '例会');
    });

    test('ASCII 大小写统一', () {
      expect(normalizeTaskTitle('Meeting'), 'meeting');
    });

    test('纯符号归一化为空串（调用方据此跳过）', () {
      expect(normalizeTaskTitle('！！！'), '');
    });
  });

  group('isSameTask', () {
    test('同标题 + 同时间 → 同一件事', () {
      expect(isSameTask(task(startAt: t0), title: '交周报', startAt: t0), isTrue);
    });

    test('标题经归一化后相等也算（标点/全角/emoji 差异）', () {
      expect(
          isSameTask(task(title: '交周报！', startAt: t0),
              title: '交周报', startAt: t0),
          isTrue);
    });

    test('同标题但时间不同 → 不是同一件事（不合并）', () {
      expect(
          isSameTask(task(startAt: t0),
              title: '交周报', startAt: t0 + 60 * 60 * 1000),
          isFalse);
    });

    test('时间容差 1 分钟内的秒级抖动 → 仍算同一件事', () {
      expect(
          isSameTask(task(startAt: t0), title: '交周报', startAt: t0 + 30 * 1000),
          isTrue);
      expect(
          isSameTask(task(startAt: t0), title: '交周报', startAt: t0 + 2 * 60 * 1000),
          isFalse);
    });

    test('两边都没时间 → 同一件事', () {
      expect(isSameTask(task(), title: '交周报'), isTrue);
    });

    test('一个有时间的和一个没时间的 → 不合并', () {
      expect(isSameTask(task(), title: '交周报', startAt: t0), isFalse);
      expect(isSameTask(task(startAt: t0), title: '交周报'), isFalse);
    });

    test('标题不同 → 不合并', () {
      expect(isSameTask(task(startAt: t0), title: '写周报', startAt: t0), isFalse);
    });
  });

  group('findReusableTask', () {
    test('命中进行中的同名同时间任务', () {
      final list = [task(id: 'a', startAt: t0)];
      expect(findReusableTask(list, title: '交周报', startAt: t0)?.id, 'a');
    });

    test('已完成的任务不参与复用（同一件事再次出现应新建）', () {
      final list = [task(id: 'done1', startAt: t0, status: TaskStatus.done)];
      expect(findReusableTask(list, title: '交周报', startAt: t0), isNull);
    });

    test('没有候选时返回 null', () {
      expect(findReusableTask(const [], title: '交周报', startAt: t0), isNull);
    });

    test('多条命中取时间最接近的那条', () {
      final list = [
        task(id: 'far', startAt: t0 + 50 * 1000, createdAt: 1),
        task(id: 'near', startAt: t0, createdAt: 2),
      ];
      expect(findReusableTask(list, title: '交周报', startAt: t0)?.id, 'near');
    });

    test('同批内新建的任务也能命中（同消息两个相同草稿只建一条）', () {
      final created = task(id: 'new', startAt: t0, createdAt: 9);
      final pool = <Task>[created];
      expect(findReusableTask(pool, title: '交周报', startAt: t0)?.id, 'new');
    });
  });
}
