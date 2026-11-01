import '../models/task.dart';

/// 归一化任务标题，用于「是不是同一件事」的本地判定。
///
/// 只做机械归一化，**不做模糊/语义匹配** —— 宁可漏合并，也不能把两件不同的事
/// 合成一条：全角转半角、去空白、去中英文标点与常见符号/emoji、ASCII 小写。
String normalizeTaskTitle(String raw) {
  final buf = StringBuffer();
  for (final r in raw.runes) {
    // 全角 ASCII（！-～）与全角空格
    var c = r;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000) c = 0x20;
    // 空白
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) continue;
    // ASCII 标点/符号
    if ((c >= 0x21 && c <= 0x2F) ||
        (c >= 0x3A && c <= 0x40) ||
        (c >= 0x5B && c <= 0x60) ||
        (c >= 0x7B && c <= 0x7E)) {
      continue;
    }
    // 中文标点与常用符号
    if (_cjkPunct.contains(String.fromCharCode(c))) continue;
    // emoji / 装饰符号（常见区段，粗粒度即可：这些字符不承载语义）
    if ((c >= 0x2190 && c <= 0x21FF) ||
        (c >= 0x2300 && c <= 0x23FF) ||
        (c >= 0x2500 && c <= 0x27BF) ||
        (c >= 0x2B00 && c <= 0x2BFF) ||
        c == 0xFE0F ||
        (c >= 0x1F000 && c <= 0x1FAFF)) {
      continue;
    }
    buf.writeCharCode(c);
  }
  return buf.toString().toLowerCase();
}

const String _cjkPunct = '、。〃〈〉《》「」『』【】〔〕〖〗〝〞〟“”‘’…—–～·：；！？，．（）｀';

/// 草稿与已有任务是否是「同一件事」。
///
/// 判定（全部满足才算）：
/// - 归一化标题完全相等；
/// - 时间一致：都无时间，或都有且相差 ≤ [minutesTolerance] 分钟
///   （AI 只输出到分钟，容差覆盖秒级抖动）。
bool isSameTask(
  Task existing, {
  required String title,
  int? startAt,
  int minutesTolerance = 1,
}) {
  if (normalizeTaskTitle(existing.title) != normalizeTaskTitle(title)) {
    return false;
  }
  final a = existing.startAt;
  if (a == null && startAt == null) return true;
  if (a == null || startAt == null) return false;
  return (a - startAt).abs() <= minutesTolerance * 60 * 1000;
}

/// 在「进行中」任务里找可复用的那一条（找到 → 不新建，改建成关联）。
///
/// 只考虑 status=active 的任务：已完成/已放弃的任务重复出现时应当新建。
/// 多条命中时取开始时间最接近、其次创建时间最早的（结果稳定可测）。
Task? findReusableTask(
  Iterable<Task> candidates, {
  required String title,
  int? startAt,
  int minutesTolerance = 1,
}) {
  Task? best;
  for (final t in candidates) {
    if (t.status != TaskStatus.active) continue;
    if (!isSameTask(t,
        title: title, startAt: startAt, minutesTolerance: minutesTolerance)) {
      continue;
    }
    if (best == null) {
      best = t;
      continue;
    }
    if (_closer(t, best, startAt)) best = t;
  }
  return best;
}

/// t 是否比 best 更该被复用：时间更近优先，其次创建更早优先。
bool _closer(Task t, Task best, int? startAt) {
  final ta = t.startAt;
  final ba = best.startAt;
  if (ta != null && ba != null && startAt != null) {
    final dt = (ta - startAt).abs();
    final db = (ba - startAt).abs();
    if (dt != db) return dt < db;
  }
  return t.createdAt < best.createdAt;
}
