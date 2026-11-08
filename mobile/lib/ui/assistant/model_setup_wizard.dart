import 'package:flutter/material.dart';

import '../../services/ai_client.dart';
import '../../services/model_capabilities.dart';

/// 模型配置向导（assistant-v4-ui §5.2）：三步 Stepper——
/// 选模板 → 填密钥+测连接 → 能力与保存。
/// 保存后 Navigator.pop 返回落盘后的 [AiEndpoint]（取消返回 null）。
Future<AiEndpoint?> showModelSetupWizard(BuildContext context,
        {AiEndpoint? existing}) =>
    Navigator.of(context).push<AiEndpoint>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ModelSetupWizardPage(existing: existing),
    ));

/// 供应商模板（§5.2 第一步）：选中预填 baseUrl + 推荐模型名。
/// 纯数据、不可变，便于单测；suggestedModel 尽量取
/// model_capabilities.knownVisionModels 白名单内的型号，让第三步的
/// 视觉能力预勾有依据。
class ProviderTemplate {
  final String id;
  final String name;
  final String letter;
  final String baseUrl;
  final String suggestedModel;
  final bool isCustom;

  const ProviderTemplate({
    required this.id,
    required this.name,
    required this.letter,
    required this.baseUrl,
    required this.suggestedModel,
    this.isCustom = false,
  });
}

const kProviderTemplates = <ProviderTemplate>[
  ProviderTemplate(
      id: 'deepseek',
      name: 'DeepSeek',
      letter: 'D',
      baseUrl: 'https://api.deepseek.com',
      suggestedModel: 'deepseek-flash'),
  ProviderTemplate(
      id: 'qwen',
      name: '通义千问',
      letter: 'Q',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      suggestedModel: 'qwen3.7-plus'),
  ProviderTemplate(
      id: 'zhipu',
      name: '智谱',
      letter: 'Z',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      suggestedModel: 'glm-5.3-flash'),
  ProviderTemplate(
      id: 'moonshot',
      name: 'Moonshot Kimi',
      letter: 'M',
      baseUrl: 'https://api.moonshot.cn/v1',
      suggestedModel: 'kimi-k3.1-pro'),
  ProviderTemplate(
      id: 'openai',
      name: 'OpenAI',
      letter: 'O',
      baseUrl: 'https://api.openai.com/v1',
      suggestedModel: 'gpt-5.2'),
  ProviderTemplate(
      id: 'custom',
      name: '自定义',
      letter: '+',
      baseUrl: '',
      suggestedModel: '',
      isCustom: true),
];

/// 测试失败的一行排查建议（§5.2 失败分类提示）。纯函数便于单测。
@visibleForTesting
String testFailureAdvice(String error) {
  if (error.contains('401') || error.contains('403')) {
    return '密钥无效或权限不足：检查 API Key 是否填对、是否过期。';
  }
  if (error.contains('404')) {
    return '路径有误：检查 Base URL 是否多/少了路径段（如 /v1）。';
  }
  if (error.contains('无法连接') || error.contains('Timeout')) {
    return '无法连接：检查网络，以及 Base URL 的域名与端口是否可达。';
  }
  return '按上方错误信息排查；也可以先保存，稍后再测。';
}

enum _TestStatus { idle, testing, passed, failed }

class ModelSetupWizardPage extends StatefulWidget {
  final AiEndpoint? existing;

  const ModelSetupWizardPage({super.key, this.existing});

  @override
  State<ModelSetupWizardPage> createState() => _ModelSetupWizardPageState();
}

class _ModelSetupWizardPageState extends State<ModelSetupWizardPage> {
  int _step = 0;
  late ProviderTemplate _template;
  late final String _endpointId;

  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _name;
  bool _obscureKey = true;
  bool? _vision; // null = 自动（按模型能力推断）

  _TestStatus _testStatus = _TestStatus.idle;
  String? _testMessage;
  List<String> _modelIds = const [];
  int? _latencyMs;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _endpointId = e?.id ?? AiClient.instance.newEndpointId();
    _template = kProviderTemplates.last; // 编辑模式不从模板预填
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _name = TextEditingController(text: e?.name ?? '');
    _vision = e?.vision;
    if (_isEdit) _step = 1; // 编辑直接进入连接步，模板步可返回查看
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _name.dispose();
    super.dispose();
  }

  String get _normalizedBaseUrl {
    var b = _baseUrl.text.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  void _pickTemplate(ProviderTemplate t) {
    setState(() {
      _template = t;
      if (!t.isCustom) {
        _baseUrl.text = t.baseUrl;
        _model.text = t.suggestedModel;
        if (_name.text.trim().isEmpty) _name.text = t.name;
      }
      _resetTest();
    });
  }

  /// 连接参数被改动后，旧的测试结果失效，必须重测（§5.2 防呆）。
  void _resetTest() {
    _testStatus = _TestStatus.idle;
    _testMessage = null;
    _modelIds = const [];
    _latencyMs = null;
  }

  Future<void> _runTest() async {
    setState(() {
      _testStatus = _TestStatus.testing;
      _testMessage = null;
    });
    final probe = AiEndpoint(
      id: _endpointId,
      name: '',
      baseUrl: _normalizedBaseUrl,
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    );
    try {
      final r = await AiClient.instance.testEndpointDetailed(probe);
      if (!mounted) return;
      setState(() {
        _testStatus = _TestStatus.passed;
        _latencyMs = r.latencyMs;
        _modelIds = r.modelIds;
        _testMessage = '连接成功 · ${r.latencyMs}ms'
            '${r.modelIds.isEmpty ? '' : ' · 发现 ${r.modelIds.length} 个模型'}';
        if (_model.text.trim().isEmpty && r.modelIds.isNotEmpty) {
          _model.text = r.modelIds.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testStatus = _TestStatus.failed;
        _testMessage = '$e';
        _modelIds = const [];
      });
    }
  }

  /// 放行规则（§5.2）：测试通过才放行；自定义模板允许跳过但标黄「未验证」；
  /// 编辑模式且未改动连接参数时视为沿用已验证配置。
  bool get _canLeaveConnectionStep {
    if (_normalizedBaseUrl.isEmpty) return false;
    if (_testStatus == _TestStatus.passed) return true;
    if (_template.isCustom) return true;
    return _isEdit && _testStatus == _TestStatus.idle;
  }

  bool get _unverifiedSkip =>
      _canLeaveConnectionStep && _testStatus != _TestStatus.passed;

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final model = _model.text.trim();
    if (name.isEmpty || _normalizedBaseUrl.isEmpty || model.isEmpty) return;
    setState(() => _saving = true);
    final ai = AiClient.instance;
    final endpoint =
        (widget.existing ?? AiEndpoint(id: _endpointId, name: '', baseUrl: ''))
            .copyWith(
      name: name,
      baseUrl: _normalizedBaseUrl,
      apiKey: _apiKey.text.trim(),
      model: model,
      vision: () => _vision,
    );
    await ai.upsertEndpoint(endpoint);
    // 第一个远程接口自动设为默认
    if (await ai.getDefaultEndpointId() == null) {
      await ai.setDefaultEndpointId(endpoint.id);
    }
    // 本次测试的诊断随保存落盘（测试时端点可能还没入库，落盘后补记一次）
    if (_testStatus == _TestStatus.passed) {
      await ai.recordEndpointTestResult(endpoint.id, latencyMs: _latencyMs);
    } else if (_testStatus == _TestStatus.failed && _testMessage != null) {
      await ai.recordEndpointTestResult(endpoint.id, error: _testMessage);
    }
    if (!mounted) return;
    Navigator.of(context).pop(
        (await ai.getRemoteEndpoints()).firstWhere((e) => e.id == endpoint.id,
            orElse: () => endpoint));
  }

  void _onContinue() {
    if (_step == 0) {
      setState(() => _step = 1);
    } else if (_step == 1) {
      if (_canLeaveConnectionStep) setState(() => _step = 2);
    } else {
      _save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑接口' : '添加接口')),
      body: Stepper(
        currentStep: _step,
        onStepContinue: _onContinue,
        onStepCancel:
            _step > (_isEdit ? 1 : 0) ? () => setState(() => _step--) : null,
        controlsBuilder: (context, details) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              FilledButton(
                // 注意用 details.stepIndex 而不是 _step：Stepper 会为每一步
                // 都构建一次控制行，用当前步序号会导致三个按钮同名同 Key
                key: ValueKey('wizard-continue-${details.stepIndex}'),
                onPressed: (_step == 1 && !_canLeaveConnectionStep) ||
                        (_step == 2 && _saving)
                    ? null
                    : details.onStepContinue,
                child: Text(_step == 2 ? '保存' : '下一步'),
              ),
              if (details.onStepCancel != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  key: ValueKey('wizard-cancel-${details.stepIndex}'),
                  onPressed: details.onStepCancel,
                  child: const Text('上一步'),
                ),
              ],
            ],
          ),
        ),
        steps: [
          Step(
            title: const Text('选择供应商'),
            isActive: _step >= 0,
            state: _step > 0 ? StepState.complete : StepState.indexed,
            content: _buildTemplateGrid(cs),
          ),
          Step(
            title: const Text('连接与密钥'),
            isActive: _step >= 1,
            state: _testStatus == _TestStatus.passed
                ? StepState.complete
                : StepState.indexed,
            content: _buildConnectionStep(cs),
          ),
          Step(
            title: const Text('能力与保存'),
            isActive: _step >= 2,
            content: _buildCapabilityStep(cs),
          ),
        ],
      ),
    );
  }

  Widget _buildTemplateGrid(ColorScheme cs) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final t in kProviderTemplates)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _pickTemplate(t),
            child: Container(
              width: 96,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _template.id == t.id
                      ? cs.primary
                      : cs.outlineVariant,
                  width: _template.id == t.id ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: _template.id == t.id
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest,
                    child: Text(t.letter,
                        style: TextStyle(
                            color: _template.id == t.id
                                ? cs.onPrimaryContainer
                                : cs.onSurfaceVariant)),
                  ),
                  const SizedBox(height: 6),
                  Text(t.name,
                      style: const TextStyle(fontSize: 12),
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildConnectionStep(ColorScheme cs) {
    final hint = _baseUrl.text.trim().isEmpty
        ? null
        : AiClient.endpointConfigHint(_baseUrl.text);
    final modelOptions = <String>{
      ..._modelIds,
      if (_model.text.trim().isNotEmpty) _model.text.trim(),
    }.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _baseUrl,
          decoration: InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.example.com/v1',
            errorText: hint,
          ),
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(_resetTest),
        ),
        TextField(
          controller: _apiKey,
          obscureText: _obscureKey,
          decoration: InputDecoration(
            labelText: 'API Key（可空）',
            suffixIcon: IconButton(
              tooltip: _obscureKey ? '显示' : '隐藏',
              icon: Icon(
                  _obscureKey ? Icons.visibility_off : Icons.visibility,
                  size: 20),
              onPressed: () => setState(() => _obscureKey = !_obscureKey),
            ),
          ),
          onChanged: (_) => setState(_resetTest),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _testStatus == _TestStatus.testing ||
                      _normalizedBaseUrl.isEmpty
                  ? null
                  : _runTest,
              icon: _testStatus == _TestStatus.testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(
                  _testStatus == _TestStatus.testing ? '测试中…' : '测试连接'),
            ),
            if (_unverifiedSkip) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text('未验证',
                    style: TextStyle(fontSize: 12, color: cs.tertiary)),
              ),
            ],
          ],
        ),
        if (_testMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _testMessage!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _testStatus == _TestStatus.passed
                        ? cs.primary
                        : cs.error,
                  ),
                ),
                if (_testStatus == _TestStatus.failed)
                  Text(testFailureAdvice(_testMessage!),
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_testStatus == _TestStatus.passed && modelOptions.isNotEmpty)
          DropdownButtonFormField<String>(
            // initialValue 只在创建时读取；选中值变化时用 Key 强制重建
            key: ValueKey('model:${_model.text.trim()}'),
            initialValue: modelOptions.contains(_model.text.trim())
                ? _model.text.trim()
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '模型（来自端点 /models）'),
            items: [
              for (final m in modelOptions)
                DropdownMenuItem(value: m, child: Text(m)),
            ],
            onChanged: (v) => setState(() => _model.text = v ?? ''),
          )
        else
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: '模型'),
            onChanged: (_) => setState(() {}),
          ),
      ],
    );
  }

  Widget _buildCapabilityStep(ColorScheme cs) {
    final support =
        resolveVisionSupport(model: _model.text, configured: _vision);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          decoration: InputDecoration(
              labelText: '备注名',
              hintText: _template.isCustom ? '我的接口' : _template.name),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<bool?>(
          initialValue: _vision,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '视觉（图像输入）'),
          items: const [
            DropdownMenuItem(value: null, child: Text('自动（按模型能力推断）')),
            DropdownMenuItem(value: true, child: Text('支持（发送图片）')),
            DropdownMenuItem(value: false, child: Text('关闭（不发送图片）')),
          ],
          onChanged: (v) => setState(() => _vision = v),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(visionSupportLabel(support),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ),
        if (_unverifiedSkip)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('该配置未通过连接测试，保存后建议在模型配置页重测。',
                style: TextStyle(fontSize: 12, color: cs.tertiary)),
          ),
      ],
    );
  }
}
