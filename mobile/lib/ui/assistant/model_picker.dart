import 'package:flutter/material.dart';

import '../../services/ai_client.dart';
import '../../services/assistant/assistant_client.dart';
import '../../services/model_capabilities.dart';

/// 模型配置（design-v3 §5.5）：
/// - 电脑端（置顶只读）：连接状态/配对 + GET /v1/models 上报的模型列表；
/// - 远程端点 CRUD：从设置页平移而来的 AiEndpoint 管理；
/// - 选择模式（selectionMode=true，对话页「每对话绑定模型」入口）：
///   点选后 Navigator.pop(modelConfigId)（空串 = 解除绑定走默认路由）。
class ModelPickerPage extends StatefulWidget {
  final bool selectionMode;
  final String? currentModelConfigId;

  const ModelPickerPage({
    super.key,
    this.selectionMode = false,
    this.currentModelConfigId,
  });

  @override
  State<ModelPickerPage> createState() => _ModelPickerPageState();
}

class _ModelPickerPageState extends State<ModelPickerPage> {
  bool? _desktopOnline;
  String _token = '';
  String? _desktopDeviceName;
  List<DesktopModelEntry> _desktopModels = [];
  String? _desktopDefaultModelId;
  String? _desktopModelsError;
  List<AiEndpoint> _remotes = [];
  final Set<String> _testing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ai = AiClient.instance;
    final remotes = await ai.getRemoteEndpoints();
    final token = await ai.getDesktopToken();
    final deviceName = await ai.getDesktopDeviceName();
    final online = await ai.isDesktopOnline();
    List<DesktopModelEntry> models = [];
    String? defaultModelId;
    String? modelsError;
    if (online) {
      try {
        final result = await AssistantClient.instance.getDesktopModels();
        models = result.models;
        defaultModelId = result.defaultModelId;
      } catch (e) {
        modelsError = '$e';
      }
    }
    if (!mounted) return;
    setState(() {
      _remotes = remotes;
      _token = token;
      _desktopDeviceName = deviceName.isEmpty ? null : deviceName;
      _desktopOnline = online;
      _desktopModels = models;
      _desktopDefaultModelId = defaultModelId;
      _desktopModelsError = modelsError;
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  void _select(String modelConfigId) {
    if (widget.selectionMode) Navigator.of(context).pop(modelConfigId);
  }

  // ---- 端点测试 / 编辑 / 删除（自设置页平移） ----

  Future<void> _testEndpoint(AiEndpoint endpoint) async {
    setState(() => _testing.add(endpoint.id));
    try {
      final msg = await AiClient.instance.testEndpoint(endpoint);
      _toast('${endpoint.name}：$msg');
    } catch (e) {
      _toast('${endpoint.name}：$e');
    } finally {
      await _load();
      if (mounted) setState(() => _testing.remove(endpoint.id));
    }
  }

  Future<void> _editEndpoint([AiEndpoint? existing]) async {
    final ai = AiClient.instance;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final baseUrlController =
        TextEditingController(text: existing?.baseUrl ?? '');
    final apiKeyController =
        TextEditingController(text: existing?.apiKey ?? '');
    final modelController = TextEditingController(text: existing?.model ?? '');
    bool? vision = existing?.vision; // null = 自动（按模型能力推断）
    final saved = await showDialog<AiEndpoint>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加接口' : '编辑接口'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                TextField(
                  controller: baseUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com/v1',
                  ),
                ),
                TextField(
                  controller: apiKeyController,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'API Key（可空）'),
                ),
                TextField(
                  controller: modelController,
                  decoration: const InputDecoration(labelText: '模型'),
                  onChanged: (_) => setDialogState(() {}),
                ),
                // B11：三态而不是开关——
                // 「自动」交给模型能力表（已知视觉模型自动支持），
                // 「关闭」才是用户显式覆盖；未知模型显示「未确认」且不发送图片。
                DropdownButton<bool?>(
                  isExpanded: true,
                  value: vision,
                  items: const [
                    DropdownMenuItem(
                        value: null, child: Text('自动（按模型能力推断）')),
                    DropdownMenuItem(value: true, child: Text('支持（发送图片）')),
                    DropdownMenuItem(
                        value: false, child: Text('关闭（不发送图片）')),
                  ],
                  onChanged: (v) => setDialogState(() => vision = v),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    visionSupportLabel(resolveVisionSupport(
                        model: modelController.text, configured: vision)),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                var baseUrl = baseUrlController.text.trim();
                if (baseUrl.endsWith('/')) {
                  baseUrl = baseUrl.substring(0, baseUrl.length - 1);
                }
                if (nameController.text.trim().isEmpty ||
                    baseUrl.isEmpty ||
                    modelController.text.trim().isEmpty) {
                  return;
                }
                Navigator.of(context).pop(
                  (existing ??
                          AiEndpoint(
                            id: ai.newEndpointId(),
                            name: '',
                            baseUrl: '',
                          ))
                      .copyWith(
                    name: nameController.text.trim(),
                    baseUrl: baseUrl,
                    apiKey: apiKeyController.text.trim(),
                    model: modelController.text.trim(),
                    vision: () => vision,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await ai.upsertEndpoint(saved);
    // 第一个远程接口自动设为默认
    if (await ai.getDefaultEndpointId() == null) {
      await ai.setDefaultEndpointId(saved.id);
    }
    await _load();
  }

  Future<void> _deleteEndpoint(AiEndpoint endpoint) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除接口'),
        content: Text('删除「${endpoint.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await AiClient.instance.deleteEndpoint(endpoint.id);
    await _load();
  }

  // ---- 配对（自设置页「连接」段平移） ----

  String get _maskedToken {
    if (_token.isEmpty) return '未配对（首次使用时自动配对）';
    final head = _token.length <= 6 ? _token : _token.substring(0, 6);
    return '$head••••••';
  }

  Future<void> _resetPairing() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置配对'),
        content: const Text('LinkModel 将重新签发 token，本机自动完成重新配对。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final (_, deviceName) = await AiClient.instance.pairDesktop(reset: true);
      _desktopDeviceName = deviceName;
      _toast('已重新配对${deviceName.isNotEmpty ? '：$deviceName' : ''}');
    } catch (e) {
      _toast('重置配对失败：$e');
    }
    await _load();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final online = _desktopOnline == true;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.selectionMode ? '选择模型' : '模型配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.selectionMode)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                (widget.currentModelConfigId ?? '').isEmpty
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 20,
              ),
              title: const Text('默认（LinkModel 在线时走 LinkModel，否则走默认远程接口）'),
              onTap: () => _select(''),
            ),
          Text('LinkModel 接口（自动置顶）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(online ? Icons.computer : Icons.computer_outlined,
                  color: online ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(online ? '已连接' : '未连接'),
                    Text(
                      '${_desktopDeviceName != null ? '$_desktopDeviceName · ' : ''}$onlineStatusHint(online)',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () async {
                  await AiClient.instance.isDesktopOnline(force: true);
                  await _load();
                },
                child: const Text('刷新'),
              ),
            ],
          ),
          Row(
            children: [
              Icon(Icons.key_outlined, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(_maskedToken,
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: cs.onSurfaceVariant)),
              ),
              TextButton(
                onPressed: online ? _resetPairing : null,
                child: const Text('重置配对'),
              ),
            ],
          ),
          if (!online)
            Text('USB 连接后执行 adb reverse tcp:8765 tcp:8765',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          if (_desktopModelsError != null)
            Text('模型列表拉取失败：$_desktopModelsError',
                style: TextStyle(fontSize: 12, color: cs.error)),
          for (final m in _desktopModels) _buildDesktopModelTile(m, cs),
          const Divider(height: 32),
          Text('远程接口', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('LinkModel 不在线时使用；对话也可直接绑定某个远程接口',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          for (final e in _remotes) _buildRemoteTile(e, cs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _editEndpoint(),
              icon: const Icon(Icons.add),
              label: const Text('添加远程接口'),
            ),
          ),
        ],
      ),
    );
  }

  String onlineStatusHint(bool online) => online ? '模型由 LinkModel 管理' : '离线';

  Widget _buildDesktopModelTile(DesktopModelEntry m, ColorScheme cs) {
    final reachable = m.reachable;
    final selected = widget.currentModelConfigId == m.id;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: widget.selectionMode
          ? Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20)
          : Icon(Icons.smart_toy_outlined, color: cs.onSurfaceVariant),
      title: Text(
          '${m.name}${m.id == _desktopDefaultModelId ? '（默认）' : ''}${selected && widget.selectionMode ? ' ✓' : ''}'),
      subtitle: Text(
        '${m.model} · ${reachable == null ? '未探测' : reachable ? '可达' : '不可达'}${visionSupportBadge(m.visionSupport)}',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      onTap: widget.selectionMode ? () => _select(m.id) : null,
    );
  }

  Widget _buildRemoteTile(AiEndpoint e, ColorScheme cs) {
    final testing = _testing.contains(e.id);
    final selected = widget.currentModelConfigId == e.id;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: widget.selectionMode
          ? Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20)
          : Icon(Icons.cloud_outlined, color: cs.onSurfaceVariant),
      title: Text('${e.name}${selected && widget.selectionMode ? ' ✓' : ''}'),
      subtitle: Text(
          '${e.baseUrl} · ${e.model}'
          '${visionSupportBadge(resolveVisionSupport(model: e.model, configured: e.vision))}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      onTap: widget.selectionMode ? () => _select(e.id) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: testing ? null : () => _testEndpoint(e),
            child: testing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('测试'),
          ),
          if (!widget.selectionMode) ...[
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editEndpoint(e),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteEndpoint(e),
            ),
          ],
        ],
      ),
    );
  }
}
