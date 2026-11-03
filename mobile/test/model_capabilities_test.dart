import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/model_capabilities.dart';

/// B11 回归：视觉能力三态识别。
///
/// 真机事实：DeepSeek V4.1 Flash 1017 支持图片输入，但旧端点配置的 vision 缺省 false，
/// 被误判成「不支持」→ 图片附件被剥成文字。这里钉住四条边界：
/// 已知识别 / 别名归一化 / 显式关闭覆盖 / 未知模型安全默认。
void main() {
  group('normalizeModelId', () {
    test('小写 + 去空白 + 去 provider 前缀', () {
      expect(normalizeModelId('  DeepSeek-Flash '), 'deepseek-flash');
      expect(normalizeModelId('deepseek/deepseek-v4.1-flash'), 'deepseek-v4.1-flash');
      expect(normalizeModelId('openai/1017'), '1017');
    });

    test('不吞掉未知变体（不做模糊匹配）', () {
      expect(normalizeModelId('deepseek-flash-plus'), 'deepseek-flash-plus');
      expect(normalizeModelId('gpt-4o'), 'gpt-4o');
    });
  });

  group('已知识别（未配置时自动支持）', () {
    test('deepseek-flash / deepseek-v4.1-flash / 1017 均识别为支持', () {
      for (final m in ['deepseek-flash', 'deepseek-v4.1-flash', '1017']) {
        expect(isKnownVisionModel(m), isTrue, reason: '$m 应在白名单');
        expect(resolveVisionSupport(model: m), VisionSupport.supported,
            reason: '$m 未配置时应自动支持');
      }
    });

    test('别名与大小写/前缀都能命中', () {
      expect(resolveVisionSupport(model: 'DeepSeek-V4.1-Flash-1017'),
          VisionSupport.supported);
      expect(resolveVisionSupport(model: 'deepseek/deepseek-flash'),
          VisionSupport.supported);
    });
  });

  group('按厂商官方文档扩充的白名单（2026-11-03）', () {
    // 只列官方明确声明支持图像/多模态的型号
    const vendorModels = <String>[
      'qwen3.7-plus',
      'qwen3.7-plus-2026-05-26',
      'qwen3.5-flash',
      'glm-5.3-flash',
      'kimi-k3.1-pro',
      'kimi-k3.1-pro-highspeed',
      'doubao-seed-2-1-pro-260915',
      'doubao-seed-2-1-lite-260915',
      'doubao-seed-2-1-turbo-260628',
      'doubao-seed-evolving',
      'ernie-5.0',
      'ernie-5.0-thinking-preview',
      'ernie-5.0-thinking-latest',
    ];

    test('官方明确多模态的型号全部识别为支持', () {
      for (final m in vendorModels) {
        expect(isKnownVisionModel(m), isTrue, reason: '$m 应在白名单');
        expect(resolveVisionSupport(model: m), VisionSupport.supported,
            reason: '$m 未配置时应自动支持');
        expect(visionAllowsImages(resolveVisionSupport(model: m)), isTrue);
      }
    });

    test('大小写与 provider 前缀同样命中（沿用既有归一化）', () {
      expect(resolveVisionSupport(model: 'Qwen3.7-Plus'),
          VisionSupport.supported);
      expect(resolveVisionSupport(model: 'dashscope/qwen3.5-flash'),
          VisionSupport.supported);
      expect(
          resolveVisionSupport(model: 'volcengine-ark/doubao-seed-evolving'),
          VisionSupport.supported);
      expect(resolveVisionSupport(model: 'anthropic/kimi-k3.1-pro'),
          VisionSupport.supported,
          reason: '前缀只做机械剥离，不参与判定');
    });

    test('官方未明确多模态的型号仍为 unknown（不猜）', () {
      for (final m in [
        'qwen-plus',
        'glm-5.3',
        'glm-5.2',
        'ernie-4.5-turbo-128k',
        'doubao-seed-2-0-pro-260215',
      ]) {
        expect(isKnownVisionModel(m), isFalse, reason: '$m 不应进白名单');
        expect(resolveVisionSupport(model: m), VisionSupport.unknown);
      }
    });
  });

  group('显式值优先', () {
    test('显式 false 是用户关闭，已知模型也不破例', () {
      expect(resolveVisionSupport(model: 'deepseek-flash', configured: false),
          VisionSupport.disabled);
      expect(visionAllowsImages(VisionSupport.disabled), isFalse);
    });

    test('显式 true 是用户开启（未知模型也照发）', () {
      expect(resolveVisionSupport(model: 'some-local-model', configured: true),
          VisionSupport.supported);
      expect(visionAllowsImages(VisionSupport.supported), isTrue);
    });
  });

  group('未知模型安全默认', () {
    test('未配置的未知模型 → unknown，且不放行图片', () {
      expect(resolveVisionSupport(model: 'gpt-4o'), VisionSupport.unknown);
      expect(visionAllowsImages(VisionSupport.unknown), isFalse,
          reason: '未确认不得冒充支持，否则端点会拒绝请求');
    });

    test('空模型名 → unknown（不 panic、不猜）', () {
      expect(resolveVisionSupport(model: ''), VisionSupport.unknown);
    });
  });

  group('文案与解析', () {
    test('三态文案互不相同且不谎报', () {
      expect(visionSupportLabel(VisionSupport.supported), contains('支持'));
      expect(visionSupportLabel(VisionSupport.disabled), contains('关闭'));
      expect(visionSupportLabel(VisionSupport.unknown), contains('未确认'));
      expect(visionSupportBadge(VisionSupport.unknown), contains('未确认'));
    });

    test('parseVisionSupport 解析 desktop 上报；未知字符串返回 null', () {
      expect(parseVisionSupport('supported'), VisionSupport.supported);
      expect(parseVisionSupport('DISABLED'), VisionSupport.disabled);
      expect(parseVisionSupport(' unknown '), VisionSupport.unknown);
      expect(parseVisionSupport('weird'), isNull);
      expect(parseVisionSupport(null), isNull);
    });
  });
}
