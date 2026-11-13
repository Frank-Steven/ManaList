import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ai_client.dart';
import '../../services/assistant/assistant_client.dart';
import '../../services/database.dart';
import '../../services/model_capabilities.dart';
import 'model_setup_wizard.dart';

/// 模型配置（assistant-v4-ui §5）：
/// - 电脑端（置顶只读）：连接状态/配对 + GET /v1/models 上报的模型列表；
/// - 远程端点 CRUD：添加/编辑走三步配置向导（model_setup_wizard.dart）；
///   行内状态点 = 最近一次连通性测试的持久化诊断（lastError/lastLatencyMs），
///   进入页面时对可见端点自动各测一次，不再只靠 SnackBar 一闪而过；
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
  String? _defaultEndpointId;
  final Set<String> _testing = {};
  bool _autoTested = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _autoTestRemotes());
  }

  Future<void> _load() async {
    final ai = AiClient.instance;
    final remotes = await ai.getRemoteEndpoints();
    final defaultId = await ai.getDefaultEndpointId();
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
      _defaultEndpointId = defaultId;
      _token = token;
      _desktopDeviceName = deviceName.isEmpty ? null : deviceName;
      _desktopOnline = online;
      _desktopModels = models;
      _desktopDefaultModelId = defaultModelId;
      _desktopModelsError = modelsError;
    });
  }

  /// 进入页面时对可见端点自动各测一次（§5.1）；结果持久化到端点诊断，
  /// 行内状态点/原因直接读取，整页只自动测一轮。
  Future<void> _autoTestRemotes() async {
    if (_autoTested || _remotes.isEmpty || !mounted) return;
    _autoTested = true;
    await Future.wait([for (final e in _remotes) _testEndpointSilent(e)]);
    await _load();
  }

  Future<void> _testEndpointSilent(AiEndpoint endpoint) async {
    if (mounted) setState(() => _testing.add(endpoint.id));
    try {
      await AiClient.instance.testEndpointDetailed(endpoint);
    } catch (_) {
      // 失败原因已持久化到端点诊断并在行内展示
    } finally {
      if (mounted) setState(() => _testing.remove(endpoint.id));
    }
  }

  /// 菜单里的手动测试：结果仍落诊断，同时 toast 完整信息。
  Future<void> _testEndpointManual(AiEndpoint endpoint) async {
    if (mounted) setState(() => _testing.add(endpoint.id));
    try {
      final r = await AiClient.instance.testEndpointDetailed(endpoint);
      _toast('${endpoint.name}：${r.message}（${r.latencyMs}ms）');
    } catch (e) {
      _toast('${endpoint.name}：$e');
    } finally {
      await _load();
      if (mounted) setState(() => _testing.remove(endpoint.id));
    }
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

  // ---- 端点 CRUD（添加/编辑走配置向导） ----

  Future<void> _openWizard([AiEndpoint? existing]) async {
    final saved = await showModelSetupWizard(context, existing: existing);
    if (saved == null) return;
    await _load();
  }

  Future<void> _setDefault(AiEndpoint endpoint) async {
    await AiClient.instance.setDefaultEndpointId(endpoint.id);
    _toast('默认远程接口：${endpoint.name}');
    await _load();
  }

  /// 删除确认（§5.1）：列出绑定它的对话数，删除后这些对话回退默认模型。
  Future<bool> _confirmDelete(AiEndpoint endpoint) async {
    final bound = await AppDatabase.instance
        .countConversationsByModelConfig(endpoint.id);
    if (!mounted) return false;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除接口'),
        content: Text('删除「${endpoint.name}」？${bound > 0 ? '\n有 $bound 个对话绑定了该接口，删除后将回退到默认模型。' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              // F3 §3.1-4：破坏性操作确认 = 一次重振
              HapticFeedback.heavyImpact();
              Navigator.of(context).pop(true);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _deleteEndpointConfirmed(AiEndpoint endpoint) async {
    await AiClient.instance.deleteEndpoint(endpoint.id);
    await _load();
  }

  Future<void> _deleteEndpoint(AiEndpoint endpoint) async {
    if (await _confirmDelete(endpoint)) {
      await _deleteEndpointConfirmed(endpoint);
    }
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
    final defaultName = _remotes
        .where((e) => e.id == _defaultEndpointId)
        .map((e) => e.name)
        .firstOrNull;
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
          Text(
              'LinkModel 不在线时使用；对话也可直接绑定某个远程接口'
              '${defaultName != null ? '；默认：$defaultName' : ''}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          for (final e in _remotes) _buildRemoteTile(e, cs),
          // 选择模式只用来选，增删改一律走「管理模型配置」。
          if (!widget.selectionMode)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _openWizard(),
                icon: const Icon(Icons.add),
                label: const Text('添加远程接口'),
              ),
            ),
          if (widget.selectionMode) ...[
            const Divider(height: 32),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.settings_outlined, size: 20),
              title: const Text('管理模型配置'),
              subtitle: const Text('测试连接 / 编辑 / 添加 / 删除接口'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: _openManagePage,
            ),
          ],
        ],
      ),
    );
  }

  String onlineStatusHint(bool online) => online ? '模型由 LinkModel 管理' : '离线';

  /// 选择页底部「管理模型配置」：进管理模式做增删改，返回后刷新列表
  /// （可能在管理页改了默认接口 / 删了当前绑定的端点）。
  Future<void> _openManagePage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ModelPickerPage()),
    );
    if (!mounted) return;
    await _load();
  }

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

  /// 状态点（§5.1，全助理域同一语义）：最近测试成功 = 绿（+延迟）、
  /// 失败 = 红（+原因一行）、未测 = 灰；测试中显示小转圈。
  Widget _statusDot(AiEndpoint e, bool testing, ColorScheme cs) {
    if (testing) {
      return const SizedBox(
          width: 20,
          height: 20,
          child: Padding(
              padding: EdgeInsets.all(4),
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final color = e.lastError != null
        ? cs.error
        : e.lastLatencyMs != null
            ? Colors.green.shade600
            : cs.onSurfaceVariant;
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  Widget _buildRemoteTile(AiEndpoint e, ColorScheme cs) {
    final testing = _testing.contains(e.id);
    final selected = widget.currentModelConfigId == e.id;
    final isDefault = e.id == _defaultEndpointId;
    final support = resolveVisionSupport(model: e.model, configured: e.vision);
    final statusText = testing
        ? '测试中…'
        : e.lastError != null
            ? '上次测试失败：${e.lastError}'
            : e.lastLatencyMs != null
                ? '上次测试正常 · ${e.lastLatencyMs}ms'
                : '未测试';
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: widget.selectionMode
          ? Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20)
          : _statusDot(e, testing, cs),
      title: Text(
          '${e.name}${isDefault ? '（默认）' : ''}${selected && widget.selectionMode ? ' ✓' : ''}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '${e.baseUrl} · ${e.model}'
              '${visionSupportBadge(support)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          Text(statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: e.lastError != null && !testing
                      ? cs.error
                      : cs.onSurfaceVariant)),
        ],
      ),
      onTap: widget.selectionMode ? () => _select(e.id) : () => _openWizard(e),
      trailing: widget.selectionMode
          ? null
          : PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) {
                switch (v) {
                  case 'test':
                    _testEndpointManual(e);
                  case 'default':
                    _setDefault(e);
                  case 'edit':
                    _openWizard(e);
                  case 'delete':
                    _deleteEndpoint(e);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'test', child: Text('测试连接')),
                PopupMenuItem(
                    value: 'default',
                    enabled: !isDefault,
                    child: const Text('设为默认')),
                const PopupMenuItem(value: 'edit', child: Text('编辑')),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
    );
    if (widget.selectionMode) return tile;
    // 管理模式：左滑删除（confirmDismiss 弹确认，列出绑定对话数；
    // F3 §3.1-3：触发距离 40% 行宽，可回弹）
    return Dismissible(
      key: ValueKey('endpoint:${e.id}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.4},
      confirmDismiss: (_) => _confirmDelete(e),
      onDismissed: (_) => _deleteEndpointConfirmed(e),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: cs.errorContainer,
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      child: tile,
    );
  }
}
