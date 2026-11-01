import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

/// 内联图像的编码结果（多模态请求用）。
typedef InlineImage = ({String dataBase64, int width, int height});

/// 图片附件内联编码：缩放到最大边 [maxSide] 后转 PNG base64。
///
/// 用 dart:ui 解码一次 + 画布缩放，避免引入 image 包依赖；
/// dart:ui 只能输出 PNG（无 JPEG），体积偏大但请求体上限（desktop 20MB）
/// 足够覆盖 1024px PNG。
///
/// 读取/解码/编码失败返回 null，调用方退化为仅文字头（不阻断对话）。
Future<InlineImage?> encodeInlineImage(String path, {int maxSide = 1024}) async {
  try {
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    var image = frame.image;
    var w = image.width;
    var h = image.height;
    if (w <= 0 || h <= 0) {
      image.dispose();
      return null;
    }
    final longest = math.max(w, h);
    if (longest > maxSide) {
      final scale = maxSide / longest;
      final tw = math.max(1, (w * scale).round());
      final th = math.max(1, (h * scale).round());
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final scaled = await recorder.endRecording().toImage(tw, th);
      image.dispose();
      image = scaled;
      w = tw;
      h = th;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return (
      dataBase64: base64Encode(data.buffer.asUint8List()),
      width: w,
      height: h,
    );
  } catch (_) {
    // 不支持的格式 / 文件已删等：退化为仅文字头
    return null;
  }
}
