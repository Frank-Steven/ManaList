/// 模型视觉能力（多模态图像输入）的唯一判定入口（B11）。
///
/// 背景：DeepSeek V4.1 Flash 1017 实际支持图片输入，但旧端点配置里 vision 缺省写死
/// false，导致手机端把图片剥成文字声明，桌面端更是完全不做门禁。这里把「支持 / 关闭 /
/// 未确认」三态收敛成一处纯逻辑，手机端与桌面端共用同一套语义
/// （shared/schemas/model-config.schema.json 的 vision 段落为事实源，两端各自实现，
/// 避免跨语言运行期依赖）。
///
/// 三态为什么必须存在：
/// - 只有 bool 时，「用户主动关闭」与「历史上从未配置」不可区分，结果是已知支持视觉的
///   模型被当成不支持（B11）；
/// - 未知模型也不能冒充支持（否则图片发过去会被端点拒绝），因此保留 [unknown]：
///   语义上等同「不附带图像」，但 UI 可以显示「未确认」而不是谎报「已关闭」。
library;

/// 视觉能力三态。
enum VisionSupport {
  /// 确定支持图像输入：图片按 content parts（image_url）内联发送。
  supported,

  /// 用户显式关闭：永不发送图像，文本照常。
  disabled,

  /// 未确认：既不知道支持、也不确定不支持。**按不支持处理**（不发送图像，避免端点报错），
  /// 但 UI 必须如实显示「未确认」，不能谎报成「已关闭」。
  unknown,
}

/// 已知支持图像输入（多模态）的模型/别名白名单（保守列举，**不猜测其它模型**）。
///
/// 依据各厂商官方文档（2026-11-03 核实）按厂商分组列举。
///
/// **故意不加**官方未明确声明多模态的型号（`qwen-plus`、`glm-5.3`、`glm-5.2`、
/// `ernie-4.5-turbo-128k` 等）：白名单宁可少，也不能让图片发到不支持的端点
/// （未知一律落回 [VisionSupport.unknown]，按「不附图」处理）。
///
/// 桌面端 `desktop/src/model-capabilities.ts` 的 `knownVisionModels` 必须与本集合一致。
const Set<String> knownVisionModels = <String>{
  // ---- DeepSeek（真机实测：V4.1 Flash 1017 支持；1017 是内部代号别名） ----
  'deepseek-flash',
  'deepseek-v4.1-flash',
  'deepseek-v4.1-flash-1017',
  '1017',
  // ---- 通义千问 / 阿里云百炼 ----
  'qwen3.7-plus',
  'qwen3.7-plus-2026-05-26',
  'qwen3.5-flash',
  // ---- 智谱 ----
  'glm-5.3-flash',
  // ---- 月之暗面 / Kimi ----
  'kimi-k3.1-pro',
  'kimi-k3.1-pro-highspeed',
  // ---- 豆包 / 火山方舟 ----
  'doubao-seed-2-1-pro-260915',
  'doubao-seed-2-1-lite-260915',
  'doubao-seed-2-1-turbo-260628',
  'doubao-seed-evolving',
  // ---- 百度千帆 ----
  'ernie-5.0',
  'ernie-5.0-thinking-preview',
  'ernie-5.0-thinking-latest',
};

/// 归一化模型标识：小写、去首尾空白、去掉 provider 前缀（deepseek/deepseek-flash）。
///
/// 只做机械归一化、不做模糊匹配——未知变体一律落回 [VisionSupport.unknown]，
/// 避免「看起来像就支持」。
String normalizeModelId(String raw) {
  var s = raw.trim().toLowerCase();
  final slash = s.lastIndexOf('/');
  if (slash >= 0 && slash < s.length - 1) s = s.substring(slash + 1);
  return s.trim();
}

/// 该模型名（含别名）是否在已知支持视觉的白名单内。
bool isKnownVisionModel(String model) =>
    knownVisionModels.contains(normalizeModelId(model));

/// 解析视觉能力三态。
///
/// [configured] 是配置里的显式值：true/false 为用户意图；null = 未配置（走能力表）。
/// 规则（与 desktop/src/model-capabilities.ts 逐条一致）：
/// 1. configured == false → [VisionSupport.disabled]（用户关闭优先，已知模型也不破例）；
/// 2. configured == true  → [VisionSupport.supported]；
/// 3. 未配置 → 已知模型 [VisionSupport.supported]，否则 [VisionSupport.unknown]。
VisionSupport resolveVisionSupport({required String model, bool? configured}) {
  if (configured == false) return VisionSupport.disabled;
  if (configured == true) return VisionSupport.supported;
  return isKnownVisionModel(model)
      ? VisionSupport.supported
      : VisionSupport.unknown;
}

/// 是否允许把图片内联进请求（只有 [VisionSupport.supported] 才允许）。
bool visionAllowsImages(VisionSupport support) =>
    support == VisionSupport.supported;

// ---- F36（2026-11-13）：推理强度能力判定 ----

/// 已知支持「推理强度参数」（`reasoning_effort` / thinking 档位）的模型白名单。
///
/// 保守列举，规则**宁可少不可多**：不确定的一律 false（不发参数 = 旧行为）。
/// 判定用 [normalizeModelId] 归一后的小写串做子串/前缀匹配：
/// - DeepSeek 推理系（deepseek-reasoner / deepseek-r1 系列）；
/// - 名字里带 thinking 的（kimi thinking / qwen thinking / glm thinking 等）；
/// - OpenAI o1 / o3 / o4 推理系列；
/// - 阿里 QwQ 推理系列。
bool isKnownReasoningModel(String model) {
  final m = normalizeModelId(model).toLowerCase();
  if (m.isEmpty) return false;
  if (m.contains('deepseek-reasoner')) return true;
  if (m.contains('deepseek-r1')) return true;
  // kimi / qwen / glm 的 thinking 型号（如 kimi-k2-thinking、glm-4.6-thinking）
  if (m.contains('thinking')) return true;
  // QwQ（阿里推理系列）
  if (m.contains('qwq')) return true;
  // OpenAI o 系列推理模型：o1 / o1-mini / o3 / o3-mini / o4-mini …
  if (RegExp(r'^o[134](?:$|-)').hasMatch(m)) return true;
  return false;
}

/// 解析「该模型是否支持推理强度参数」。
///
/// [configured] 是端点上用户显式配置的档位（null/off/low/medium/high）：
/// **非空即视为用户明确表态支持**（与视觉三态同理，显式优先于能力表）。
bool resolveReasoningSupport({required String model, String? configured}) {
  final c = configured?.trim();
  if (c != null && c.isNotEmpty) return true;
  return isKnownReasoningModel(model);
}

/// 该档位是否要真的发送 `reasoning_effort`：null（自动）与 off（显式关闭）都**不发**。
bool shouldSendReasoningEffort(String? effective) {
  final v = effective?.trim();
  if (v == null || v.isEmpty) return false;
  if (v == 'off') return false;
  return v == 'low' || v == 'medium' || v == 'high';
}

/// 表单里的完整文案：视觉：支持 / 视觉：已关闭 / 视觉：未确认。
String visionSupportLabel(VisionSupport support) => switch (support) {
      VisionSupport.supported => '视觉：支持',
      VisionSupport.disabled => '视觉：已关闭',
      VisionSupport.unknown => '视觉：未确认',
    };

/// 列表行的简短徽标（不需要时返回空串，便于字符串拼接）。
String visionSupportBadge(VisionSupport support) => switch (support) {
      VisionSupport.supported => ' · 视觉',
      VisionSupport.disabled => ' · 视觉已关',
      VisionSupport.unknown => ' · 视觉未确认',
    };

/// 解析 desktop 上报的 visionStatus 字符串；无法识别时返回 null（由调用方回退到 vision）。
VisionSupport? parseVisionSupport(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'supported':
      return VisionSupport.supported;
    case 'disabled':
      return VisionSupport.disabled;
    case 'unknown':
      return VisionSupport.unknown;
    default:
      return null;
  }
}
