import "assistant/models.dart" show ChatAttachment, ChatMessageModel;
import "model_capabilities.dart" show normalizeModelId;
import "token_estimate.dart"
    show kConservativeImageTokens, estimateTokensFromChars;

/// F41（2026-11-13）：上下文窗口上限改为「可获取」，不再硬编码 32k。
///
/// 解析优先级（F44 用户口径，高 → 低）：
///   fromEndpoint（服务端 /models 自报，最可信）> 模型表（官方文档可查）
///   > configured（用户手动填的，可能过时）> 兜底 32k（source = assumed）。
/// 注意：这与 F41 初版（configured 最高）相反，是用户明确要求的新顺序。
/// 入参 null / <= 0 视为「未提供」，继续往下走；返回值永远非空。
enum ContextWindowSource { configured, endpoint, modelTable, assumed }

/// 兜底上限：历史值（assistant-v4-ui §3.6 的 kDefaultContextTokenLimit）。
const int kAssumedContextTokenLimit = 32768;

/// 模型 → 上下文窗口（tokens）。**只收官方文档可引用并注明的型号**，
/// 查不到的一律不进表（宁缺勿编）。
///
/// 来源：DeepSeek 官方价格/模型页 https://api-docs.deepseek.com/quick_start/pricing
/// （CONTEXT LENGTH = 1M、max output = 384K；2026-11-13 核实）。
const Map<String, int> kKnownContextWindows = <String, int>{
  // DeepSeek V4.1 Flash（真机端点实际用的就是 deepseek-flash）。
  "deepseek-flash": 1000000,
  "deepseek-v4.1-flash": 1000000,
  // DeepSeek V4 Pro。
  "deepseek-v4-pro": 1000000,
  // 千问 1M 组：来源 https://platform.qianwenai.com/docs/developer-guides/
  // getting-started/text-generation-models.md（原文「qwen3.7-plus … 支持 1M 上下文」，
  // 并把 qwen3.8-max / qwen3.8-flash / qwen3.7-max 与 qwen3.7-plus 同列 1M 组）。
  "qwen3.7-plus": 1000000,
  "qwen3.7-max": 1000000,
  "qwen3.8-flash": 1000000,
  "qwen3.8-max": 1000000,
  // 智谱：来源 https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash
  // （原文「上下文窗口 1M / 最大输出 128K」）。
  "glm-5.3-flash": 1000000,
};

/// DeepSeek 的 1M 上下文常量（模型表与测试共用）。
const int kDeepSeekMillionContext = 1000000;

/// 二进制 M（1024×1024）：B30 用于把 1048576 显示成 1M 而不是 1024k。
const int kBinaryMillion = 1024 * 1024;

/// 归一后的模型名 → 已知窗口；未知返回 null。
///
/// 匹配规则（与 model_capabilities 同风格，但更严）：
/// ① 整名精确匹配；
/// ② `1017` 是 DeepSeek 内部代号别名，**只做整名匹配**——
///    绝不做子串匹配（否则 `qwen-1017` 之类会被误判）；
/// ③ 明确的族前缀（`<表内名>-<快照后缀>`，如 deepseek-flash-2026xxxx）。
int? knownContextWindowFor(String model) {
  final id = normalizeModelId(model).toLowerCase();
  if (id.isEmpty) return null;
  if (id == "1017") return kDeepSeekMillionContext;
  final direct = kKnownContextWindows[id];
  if (direct != null) return direct;
  for (final entry in kKnownContextWindows.entries) {
    if (id.startsWith("${entry.key}-")) return entry.value;
  }
  return null;
}

/// 人读上限。**厂商用的是混刻度**，不能一律按 1024 除：
/// - 十进制刻度：1000000 → `1M`、128000 → `128k`、200000 → `200k`；
/// - 二进制刻度：32768 → `32k`、131072 → `128k`（32×1024 / 128×1024）。
/// 规则=「哪个刻度能整除就用哪个」，M 优先、其次十进制 k、再其次 1024 进制 k；
/// 都不能整除时四舍五入到十进制 k（例：32767 → 33k）。
String formatContextWindowTokens(int tokens) {
  if (tokens <= 0) return "0";
  if (tokens % 1000000 == 0) return "${tokens ~/ 1000000}M";
  // B30：1,048,576 是「1024×1024」的二进制 M（不少上游按二进制报窗口）——
  // 不先判它就会落到 1024k。
  if (tokens % kBinaryMillion == 0) return "${tokens ~/ kBinaryMillion}M";
  if (tokens % 1000 == 0) return "${tokens ~/ 1000}k";
  if (tokens % 1024 == 0) return "${tokens ~/ 1024}k";
  return "${(tokens / 1000).round()}k";
}

/// 解析结果：窗口大小 + 来源（来源要显示在面板/无障碍文案里，不能含糊）。
class ContextWindowInfo {
  final int tokens;
  final ContextWindowSource source;

  const ContextWindowInfo(this.tokens, this.source);

  /// 面板/语义用的一句话说明。
  String get label {
    final size = formatContextWindowTokens(tokens);
    return switch (source) {
      ContextWindowSource.configured => "上限 $size（来源：手动配置）",
      ContextWindowSource.endpoint => "上限 $size（来源：端点上报）",
      ContextWindowSource.modelTable => "上限 $size（来源：模型能力表）",
      ContextWindowSource.assumed =>
        "上限 $size（估算，未获取到模型窗口）",
    };
  }

  @override
  String toString() => "$label [$tokens]";
}

/// 按优先级解析上下文窗口上限（永不返回空）。
ContextWindowInfo resolveContextWindow({
  required String model,
  int? configured,
  int? fromEndpoint,
}) {
  // F44 新顺序：端点自报 > 官方模型表 > 用户自填 > 默认 32k。
  if (fromEndpoint != null && fromEndpoint > 0) {
    return ContextWindowInfo(fromEndpoint, ContextWindowSource.endpoint);
  }
  final fromTable = knownContextWindowFor(model);
  if (fromTable != null && fromTable > 0) {
    return ContextWindowInfo(fromTable, ContextWindowSource.modelTable);
  }
  if (configured != null && configured > 0) {
    return ContextWindowInfo(configured, ContextWindowSource.configured);
  }
  return const ContextWindowInfo(
      kAssumedContextTokenLimit, ContextWindowSource.assumed);
}

// ---- R03-A5（task-112）：请求级上下文预算 ----

/// 对话上下文 token 的**近似**估算：历史消息字符数 / 4 + 草稿附件估算。
///
/// 原定义在 ui/assistant/widgets/reasoning_pill_row.dart；R03-A5 搬到服务层，
/// 让 UI 与服务端预算用同一口径（UI 侧改为 import，不再保留副本）。
int estimateContextTokens({
  required int historyChars,
  required int attachmentTokens,
}) {
  if (historyChars <= 0) return attachmentTokens < 0 ? 0 : attachmentTokens;
  final fromHistory = (historyChars / 4).round();
  return fromHistory + (attachmentTokens < 0 ? 0 : attachmentTokens);
}

/// 一次**请求**的预算快照（R03-A5）。
class RequestBudget {
  /// 估算用量（字符估算，非真实 tokenizer）。
  final int usedTokens;

  /// 上限（端点自报 / 模型表 / 用户配置，见 [resolveContextWindow]）。
  final int limitTokens;

  const RequestBudget(this.usedTokens, this.limitTokens);

  /// 占用比例；上限未知（<= 0）时返回 0，**不判定为超限**。
  double get ratio => limitTokens <= 0 ? 0 : usedTokens / limitTokens;

  /// 严格超过 100%（等于 100% 仍允许发送）。
  bool get over100 => limitTokens > 0 && usedTokens > limitTokens;

  /// 超过 80%（既有预警语义，对应 attachment_cards 的 budgetLevel）。
  bool get over80 => limitTokens > 0 && usedTokens > limitTokens * 0.8;

  /// 「估算 N tokens / 上限 Xk」
  String get label =>
      '估算 $usedTokens tokens / 上限 ${formatContextWindowTokens(limitTokens)}';
}

/// 估算**本次请求**的上下文用量（含说明书/工具前言与附件上下文块）。
///
/// 口径（与 UI 保持一致，不另造阈值）：
/// - 所有消息正文 + 附件上下文文本 → 字符数求和后走 [estimateTokensFromChars]（/2）；
/// - 「dataBase64 非空」的附件每个再加 [kConservativeImageTokens]
///   （B29 口径：库内图 1.4K/张）。**注意** dataBase64 可能是空串（占位），
///   空串不额外计图片 tokens，避免把纯文本附件算成图片。
///
/// 注意：这里按**字符**保守估算（CJK /2），不是真实 tokenizer；用于「超限就别发」的
/// 硬闸门与 80% 预警，不用于计费。
RequestBudget estimateRequestBudget({
  required List<ChatMessageModel> messages,
  List<ChatAttachment> attachments = const [],
  required int limitTokens,
}) {
  var chars = 0;
  for (final m in messages) {
    chars += m.content.length;
    // 附件上下文块（带 [#note:标题] 引用头）也是要发给模型的正文
    for (final a in m.attachments) {
      final text = a.content;
      if (text != null) chars += text.length;
    }
  }
  var imageTokens = 0;
  for (final a in attachments) {
    final text = a.content;
    if (text != null) chars += text.length;
    // dataBase64 非空 = 本回合要内联图片 → 按保守上界计
    if (a.dataBase64 != null && a.dataBase64!.isNotEmpty) {
      imageTokens += kConservativeImageTokens;
    }
  }
  return RequestBudget(
      estimateTokensFromChars(chars) + imageTokens, limitTokens);
}
