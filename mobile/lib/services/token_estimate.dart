import 'dart:math' as math;

/// 请求级 token 估算的唯一实现（R03-A5，task-112）。
///
/// 原本定义在 ui/assistant/widgets/attachment_cards.dart：服务层要做**发请求前**
/// 的上下文预算，就必须能 import 它；为保持依赖方向（services 不反向依赖 ui），
/// 这里把它**搬**成纯函数模块，UI 侧改为 export 转发（不留第二份实现）。

/// token 估算（§3.6）：字符数 / 2（CJK 保守估计）。
int estimateTokensFromChars(int chars) => (chars / 2).ceil();

/// 图片内联口径：encodeInlineImage 默认把长边缩到 [kInlineImageMaxSide]
/// （services/assistant/image_encoder.dart:16）。视觉开销与**像素面积**相关、
/// 与文件字节数无关 —— 用字节数会把 50KB JPEG 算成 2.5 万 token（F22）。
const int kInlineImageMaxSide = 1024;

/// 视觉 token ≈ 缩放后像素面积 / 750（业界常用近似，仅用于预算提示）。
const int kImageTokenAreaDivisor = 750;

/// 宽高未知时的**保守上界**：1024×1024 / 750 ≈ 1398.1 → 取 1400。
const int kConservativeImageTokens = 1400;

/// 图片附件的 token 估算（F22 修复）：按长边 [maxSide] 等比缩放后的面积算，
/// 不用文件字节数。宽/高未知或非法 → 回退 [kConservativeImageTokens]。
int estimateImageTokens({
  int? width,
  int? height,
  int maxSide = kInlineImageMaxSide,
}) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return kConservativeImageTokens;
  }
  var w = width;
  var h = height;
  final longest = math.max(w, h);
  if (maxSide > 0 && longest > maxSide) {
    final scale = maxSide / longest;
    w = math.max(1, (w * scale).round());
    h = math.max(1, (h * scale).round());
  }
  return math.max(1, (w * h / kImageTokenAreaDivisor).ceil());
}
