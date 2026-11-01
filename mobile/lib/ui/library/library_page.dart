import 'package:flutter/material.dart';

import '../../services/app_ui_state.dart';
import '../messages/messages_page.dart';
import '../notes/notes_page.dart';
import 'files_page.dart';

/// v3 阶段 3「库」页容器（design-v3 §3.1）：顶部三分区切换「消息 / 笔记 / 文件」，
/// 首次默认「消息」分区（带未处理数角标的采集入口）。
///
/// ui-structure §3/§6.1 收编后：整屏唯一 AppBar 由本页持有（标题「库」，
/// TabBar 收进 AppBar.bottom），三个分区页不再带 AppBar；分区级操作上收
/// （消息分区的归档箱进 AppBar actions，按分区分显隐）；领域主创建统一为
/// 本页 FAB，语义随分区切换（笔记=新建笔记本、消息=手动添加、文件=导入）。
/// 当前分区与 [AppUiState.librarySection] 双向同步，别处（如 AI 横幅）
/// 可通过 AppUiState.openLibrary 定位分区。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  final _notesKey = GlobalKey<NotesPageState>();
  final _messagesKey = GlobalKey<MessagesPageState>();
  final _filesKey = GlobalKey<FilesPageState>();

  /// 消息/文件分区处于多选态时隐藏 FAB（避免遮挡底部批量操作条）。
  bool _messagesSelecting = false;
  bool _filesSelecting = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 3,
      vsync: this,
      initialIndex: AppUiState.instance.librarySection,
    );
    _tab.addListener(_onTabChanged);
    AppUiState.instance.addListener(_syncSectionFromState);
  }

  @override
  void dispose() {
    AppUiState.instance.removeListener(_syncSectionFromState);
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  /// 用户切分区 → 回写 AppUiState（messagesVisible 等判定依赖它）；
  /// setState 驱动 AppBar actions / FAB 按分区分显隐。
  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    AppUiState.instance.setLibrarySection(_tab.index);
    setState(() {});
  }

  /// 外部（AppUiState.openLibrary）请求定位分区 → 驱动 TabController。
  void _syncSectionFromState() {
    if (!mounted) return;
    final target = AppUiState.instance.librarySection;
    if (target != _tab.index) _tab.animateTo(target);
  }

  /// 供底部导航切页时调用：刷新当前分区。
  Future<void> reload() async {
    switch (_tab.index) {
      case AppUiState.librarySectionNotes:
        await _notesKey.currentState?.reload();
      case AppUiState.librarySectionMessages:
        await reloadMessages();
      case AppUiState.librarySectionFiles:
        await _filesKey.currentState?.reload();
    }
  }

  /// AI 横幅等需要单独刷消息列表的入口。
  Future<void> reloadMessages() async =>
      _messagesKey.currentState?.reload();

  /// 领域主创建 FAB（ui-structure §4）：语义随分区切换。
  Widget? _buildFab() {
    if (_tab.index == AppUiState.librarySectionMessages &&
        _messagesSelecting) {
      return null;
    }
    if (_tab.index == AppUiState.librarySectionFiles && _filesSelecting) {
      return null;
    }
    final (tooltip, icon, onPressed) = switch (_tab.index) {
      AppUiState.librarySectionNotes => (
          '新建笔记本',
          Icons.add,
          () => _notesKey.currentState?.createNotebook(),
        ),
      AppUiState.librarySectionMessages => (
          '手动添加',
          Icons.add,
          () => _messagesKey.currentState?.addManually(),
        ),
      _ => (
          '导入文件',
          Icons.upload_file_outlined,
          () => _filesKey.currentState?.importEntry(),
        ),
    };
    return FloatingActionButton(
      tooltip: tooltip,
      onPressed: onPressed,
      child: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('库'),
        actions: [
          // 分区级操作上收（ui-structure §3）：归档箱仅消息分区显示。
          if (_tab.index == AppUiState.librarySectionMessages)
            IconButton(
              tooltip: '已归档',
              icon: const Icon(Icons.archive_outlined),
              onPressed: () => _messagesKey.currentState?.openArchived(),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: [
            // 消息分区是采集入口，带未处理数角标（与底部导航「库」同源）。
            Tab(
              child: AnimatedBuilder(
                animation: MessageBadges.instance,
                builder: (context, _) {
                  final pending = MessageBadges.instance.pending;
                  return Badge(
                    isLabelVisible: pending > 0,
                    label: Text(pending > 99 ? '99+' : '$pending'),
                    child: const Text('消息'),
                  );
                },
              ),
            ),
            const Tab(text: '笔记'),
            const Tab(text: '文件'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          MessagesPage(
            key: _messagesKey,
            onSelectionChanged: (selecting) =>
                setState(() => _messagesSelecting = selecting),
          ),
          NotesPage(key: _notesKey),
          FilesPage(
            key: _filesKey,
            onSelectionChanged: (selecting) =>
                setState(() => _filesSelecting = selecting),
          ),
        ],
      ),
      floatingActionButton: _buildFab(),
    );
  }
}
