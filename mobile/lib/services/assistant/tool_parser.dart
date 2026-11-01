import 'dart:convert';

/// 工具调用块流式解析状态机（design-v3-details §2.2）。
///
/// 模型在回复中内嵌围栏块（```tool ... ```，容错 ```json 误标），
/// 本解析器按 token 增量喂入：
/// - TEXT 段照常上屏（[ToolFeedResult.text]）；
/// - 进入块内后暂停该段上屏，块闭合 → 解析 JSON → 产出 [ParsedToolBlock]；
/// - 解析失败（坏 JSON / 缺字段）不抛出，块带 [ParsedToolBlock.parseError]
///   返回，由上层回写「一个动作未能理解，已跳过」；
/// - 流中断（[finish] interrupted=true）：未闭合块整体丢弃。
///
/// 去重键：块序号为每个解析器实例内 0 起递增（对应一条 assistant 消息的
/// blockIndex）；与 chatMessageId 组合即 details §2.3 的去重键
/// （落库提案 id = '<chatMessageId>_b<blockIndex>'，见 proposal_service）。

/// 解析出的一个工具调用块。
class ParsedToolBlock {
  /// 本条 assistant 消息内的块序号（0 起）。
  final int index;

  /// 工具名（解析失败时为 null）。
  final String? tool;

  /// 调用参数（解析失败时为 null）。
  final Map<String, dynamic>? args;

  /// 块内原文（去除围栏后的 JSON 文本， trimmed）。
  final String raw;

  /// 解析失败原因；null 表示解析成功。
  final String? parseError;

  const ParsedToolBlock({
    required this.index,
    this.tool,
    this.args,
    required this.raw,
    this.parseError,
  });

  bool get ok => parseError == null && tool != null && args != null;
}

/// 一次喂入的产出。
class ToolFeedResult {
  /// 可上屏的文本增量（TEXT 段；块内内容不含在内）。
  final String text;

  /// 本次喂入期间闭合的块。
  final List<ParsedToolBlock> blocks;

  const ToolFeedResult({this.text = '', this.blocks = const []});
}

/// finish 的产出：除文本外，报告是否丢弃了未闭合块。
class ToolFinishResult {
  final String text;
  final List<ParsedToolBlock> blocks;

  /// 流中断时未闭合块被整体丢弃（details §2.2：已落库提案保留）。
  final bool discardedUnclosedBlock;

  const ToolFinishResult({
    this.text = '',
    this.blocks = const [],
    this.discardedUnclosedBlock = false,
  });
}

enum _State { text, inBlock }

class ToolBlockParser {
  _State _state = _State.text;

  /// 未按行完整到达的尾部（跨 chunk 的行缓存）。
  String _lineBuffer = '';

  /// 块内累积的 JSON 文本。
  final StringBuffer _blockBuffer = StringBuffer();

  int _blockIndex = 0;

  /// 已闭合块数（= 下一个块的 blockIndex）。
  int get blockCount => _blockIndex;

  /// 当前是否在工具块内（流中断判定用）。
  bool get inBlock => _state == _State.inBlock;

  /// 喂入一段增量文本。
  ///
  /// TEXT 段尽量增量上屏：完整行立即处理；未完成的尾行若不含 '`'
  /// （不可能变成围栏行）也立即上屏，含 '`' 的尾行暂存等下一段——
  /// 保证围栏跨 chunk 拆分时不被误判成普通文本。
  ToolFeedResult feed(String delta) {
    if (delta.isEmpty) return const ToolFeedResult();
    _lineBuffer += delta;
    final text = StringBuffer();
    final blocks = <ParsedToolBlock>[];
    var nl = _lineBuffer.indexOf('\n');
    while (nl >= 0) {
      final line = _lineBuffer.substring(0, nl);
      _lineBuffer = _lineBuffer.substring(nl + 1);
      _processLine(line, '$line\n', text, blocks);
      nl = _lineBuffer.indexOf('\n');
    }
    if (_state == _State.text &&
        _lineBuffer.isNotEmpty &&
        !_lineBuffer.contains('`')) {
      text.write(_lineBuffer);
      _lineBuffer = '';
    }
    return ToolFeedResult(
        text: text.toString(), blocks: List.unmodifiable(blocks));
  }

  /// 流结束。interrupted=true（网络断/用户取消）时未闭合块整体丢弃；
  /// 正常结束时尾行若是闭合围栏也按闭合处理（模型偶尔省最后的换行）。
  ToolFinishResult finish({bool interrupted = false}) {
    final text = StringBuffer();
    final blocks = <ParsedToolBlock>[];
    var discarded = false;
    if (_lineBuffer.isNotEmpty) {
      final tail = _lineBuffer;
      _lineBuffer = '';
      _processLine(tail, tail, text, blocks, isFinalTail: true);
    }
    if (_state == _State.inBlock) {
      // 未闭合块：正常结束也按丢弃处理（缺闭合围栏的块不可信），
      // 但只有 interrupted 才算「流中断」语义。
      discarded = true;
      _state = _State.text;
      _blockBuffer.clear();
    }
    return ToolFinishResult(
      text: text.toString(),
      blocks: List.unmodifiable(blocks),
      discardedUnclosedBlock: discarded && interrupted,
    );
  }

  void _processLine(String line, String lineWithNl, StringBuffer text,
      List<ParsedToolBlock> blocks,
      {bool isFinalTail = false}) {
    final trimmed = line.trim();
    if (_state == _State.text) {
      if (trimmed.startsWith('```')) {
        // 围栏语言标识：tool 为约定，json 为容错误标（details §2.1）；
        // 其余语言标识/无标识的代码块是普通文本，原样上屏。
        final lang = trimmed.substring(3).trim().toLowerCase();
        if (lang == 'tool' || lang == 'json') {
          _state = _State.inBlock;
          _blockBuffer.clear();
          return;
        }
      }
      text.write(lineWithNl);
      return;
    }
    // IN_BLOCK：闭合围栏 = 整行就是 ```（容忍行内多余空白）。
    if (trimmed == '```' || trimmed.startsWith('``` ')) {
      blocks.add(_closeBlock());
      return;
    }
    if (isFinalTail && trimmed.isEmpty) return; // 末尾空行不进块
    _blockBuffer
      ..write(line)
      ..write('\n');
  }

  ParsedToolBlock _closeBlock() {
    final raw = _blockBuffer.toString().trim();
    _blockBuffer.clear();
    _state = _State.text;
    final index = _blockIndex++;
    if (raw.isEmpty) {
      return ParsedToolBlock(
          index: index, raw: raw, parseError: '工具块为空');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      return ParsedToolBlock(
          index: index, raw: raw, parseError: '工具块 JSON 解析失败：$e');
    }
    if (decoded is! Map) {
      return ParsedToolBlock(
          index: index, raw: raw, parseError: '工具块须为 JSON 对象');
    }
    final map = decoded.cast<String, dynamic>();
    final tool = map['tool'];
    final args = map['args'];
    if (tool is! String || tool.isEmpty) {
      return ParsedToolBlock(
          index: index, raw: raw, parseError: '工具块缺少 tool 字段');
    }
    return ParsedToolBlock(
      index: index,
      tool: tool,
      args: args is Map
          ? args.cast<String, dynamic>()
          : (args == null ? const {} : null),
      raw: raw,
      parseError: args == null || args is Map ? null : 'args 须为 JSON 对象',
    );
  }
}
