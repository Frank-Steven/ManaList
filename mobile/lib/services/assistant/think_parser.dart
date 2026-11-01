/// 思考块（thinking）流式解析器（2026-11-01）。
///
/// 推理模型（DeepSeek-R1 / Qwen 等经 openai-compat 通道）在正文中原生输出
/// `<think>...</think>` 标签包裹的推理过程。本解析器与 [ToolBlockParser]
/// 串联使用（先思考后工具），按 token 增量喂入：
/// - 标签外的文本照常上屏（[ThinkFeedResult.text]）；
/// - 标签内的内容累积进 [thinking] 缓冲，不上屏；
/// - 标签跨 chunk 拆分：尾部可能是标签前缀的部分暂存，等下一段再判；
/// - 一个回合可有多个思考段（思考 → 回答 → 再思考），内容统一累积，
///   [active] 报告当前是否仍在思考块内（UI 分段以事件流为准）。
library;

/// 一次喂入的产出。
class ThinkFeedResult {
  /// 可上屏的文本增量（思考内容不含在内）。
  final String text;

  /// 思考缓冲本轮是否有新增（true 时上层应重发思考增量事件）。
  final bool thinkingChanged;

  /// 思考活跃状态本轮是否翻转（进入/离开思考块）。
  final bool stateChanged;

  const ThinkFeedResult({
    this.text = '',
    this.thinkingChanged = false,
    this.stateChanged = false,
  });
}

class ThinkTagParser {
  static const _open = '<think>';
  static const _close = '</think>';

  final StringBuffer _thinking = StringBuffer();

  /// 当前思考段的内容（进入新思考段时清零，UI 按段分块）。
  final StringBuffer _section = StringBuffer();
  final StringBuffer _pending = StringBuffer();

  bool _inThink = false;

  /// 本回合已进入过的思考段数（当前段序号 = sectionCount - 1）。
  int _sectionCount = 0;

  /// 累计思考内容（全部思考段拼接）。
  String get thinking => _thinking.toString();

  /// 当前思考段序号（-1 = 尚未进入过思考块）。
  int get sectionIndex => _sectionCount - 1;

  /// 当前思考段的内容。
  String get sectionThinking => _section.toString();

  /// 当前是否在思考块内。
  bool get inThinking => _inThink;

  /// 是否产出过思考内容（流式 UI 决定是否渲染思考段）。
  bool get hasThinking => _thinking.isNotEmpty || _inThink;

  /// 喂入一段增量文本。
  ThinkFeedResult feed(String delta) {
    if (delta.isEmpty) return const ThinkFeedResult();
    _pending.write(delta);
    return _drain(finalFlush: false);
  }

  /// 流结束：暂存的标签前缀按普通内容落出（此时不可能是完整标签了）。
  ThinkFeedResult finish() => _drain(finalFlush: true);

  ThinkFeedResult _drain({required bool finalFlush}) {
    final text = StringBuffer();
    var thinkingChanged = false;
    var stateChanged = false;
    var buf = _pending.toString();
    _pending.clear();
    while (buf.isNotEmpty) {
      final tag = _inThink ? _close : _open;
      final idx = buf.indexOf(tag);
      if (idx >= 0) {
        _emit(buf.substring(0, idx), text,
            onThinking: () => thinkingChanged = true);
        _inThink = !_inThink;
        if (_inThink) {
          _sectionCount++;
          _section.clear();
        }
        stateChanged = true;
        buf = buf.substring(idx + tag.length);
        continue;
      }
      // 无完整标签：保留尾部可能是标签前缀的部分（非收尾时）
      final keep = finalFlush ? 0 : _partialSuffix(buf, tag);
      _emit(buf.substring(0, buf.length - keep), text,
          onThinking: () => thinkingChanged = true);
      buf = buf.substring(buf.length - keep);
      break;
    }
    _pending.write(buf);
    return ThinkFeedResult(
      text: text.toString(),
      thinkingChanged: thinkingChanged,
      stateChanged: stateChanged,
    );
  }

  void _emit(String chunk, StringBuffer text,
      {required void Function() onThinking}) {
    if (chunk.isEmpty) return;
    if (_inThink) {
      _thinking.write(chunk);
      _section.write(chunk);
      onThinking();
    } else {
      text.write(chunk);
    }
  }

  /// buf 尾部与 tag 前缀匹配的最大长度（0..tag.length-1）。
  static int _partialSuffix(String buf, String tag) {
    final max =
        buf.length < tag.length - 1 ? buf.length : tag.length - 1;
    for (var len = max; len > 0; len--) {
      if (buf.endsWith(tag.substring(0, len))) return len;
    }
    return 0;
  }
}
