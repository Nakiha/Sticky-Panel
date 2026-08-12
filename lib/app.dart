import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'store.dart';

/// Highlight palette (marker-style, semi-opaque so it works on light/dark).
const List<Color> kHighlightColors = [
  Color(0x00000000), // none
  Color(0x99FFD54F), // yellow
  Color(0x99A5D6A7), // green
  Color(0x9990CAF9), // blue
  Color(0x99F48FB1), // pink
  Color(0x99FFAB91), // orange
];

/// Font size presets cycled by the size button.
const List<double> kFontSizes = [13, 15, 18, 22];

class StickyPanelApp extends StatelessWidget {
  const StickyPanelApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF007AFF);
    const blueDark = Color(0xFF0A84FF);
    return MaterialApp(
      title: 'Sticky Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: blue,
          surface: Colors.white,
          onSurface: Color(0xFF1C1C1E),
          onSurfaceVariant: Color(0xFF8E8E93),
          outlineVariant: Color(0xFFE5E5EA),
          surfaceContainerHighest: Color(0xFFF2F2F7),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1C1C1E),
        colorScheme: const ColorScheme.dark(
          primary: blueDark,
          surface: Color(0xFF1C1C1E),
          onSurface: Color(0xFFF2F2F7),
          onSurfaceVariant: Color(0xFF8E8E93),
          outlineVariant: Color(0xFF38383A),
          surfaceContainerHighest: Color(0xFF2C2C2E),
        ),
      ),
      home: HomePage(store: store),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});

  final AppStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static final bool _isMac = defaultTargetPlatform == TargetPlatform.macOS;

  bool _alwaysOnTop = true;
  bool _todoExpanded = false;
  bool _todoShowAll = false;
  String? _selectedEntryId;

  /// One controller/focus node per board line, keyed by entry id, so the
  /// board behaves like a continuous editor.
  final _controllers = <String, TextEditingController>{};
  final _focusNodes = <String, FocusNode>{};

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_pruneAttachments);
  }

  @override
  void dispose() {
    store.removeListener(_pruneAttachments);
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// Drop controllers/focus nodes whose entry no longer exists.
  void _pruneAttachments() {
    final live = <String>{
      for (final p in store.projects) ...p.entries.map((e) => e.id),
    };
    for (final id in _controllers.keys.where((id) => !live.contains(id)).toList()) {
      _controllers.remove(id)?.dispose();
    }
    for (final id in _focusNodes.keys.where((id) => !live.contains(id)).toList()) {
      _focusNodes.remove(id)?.dispose();
    }
    if (_selectedEntryId != null && !live.contains(_selectedEntryId)) {
      _selectedEntryId = null;
    }
  }

  TextEditingController _controllerFor(Entry entry) =>
      _controllers.putIfAbsent(entry.id, () => TextEditingController(text: entry.text));

  FocusNode _focusNodeFor(Project project, Entry entry) {
    return _focusNodes.putIfAbsent(entry.id, () {
      final node = FocusNode();
      node.addListener(() {
        if (node.hasFocus && mounted && _selectedEntryId != entry.id) {
          setState(() => _selectedEntryId = entry.id);
        }
      });
      return node;
    })
      // Backspace on an empty line deletes it and moves focus up.
      ..onKeyEvent = (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.backspace &&
            (_controllers[entry.id]?.text.isEmpty ?? false)) {
          _removeLine(project, entry);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      };
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    setState(() {});
  }

  void _insertLineBelow(Project project, Entry? after) {
    final entry = store.insertEntryAfter(project, after);
    _controllerFor(entry);
    _focusNodeFor(project, entry);
    setState(() => _selectedEntryId = entry.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNodes[entry.id]?.requestFocus();
    });
  }

  void _removeLine(Project project, Entry entry) {
    final index = project.entries.indexOf(entry);
    final previous = index > 0 ? project.entries[index - 1] : null;
    store.removeEntry(project, entry);
    if (previous != null) {
      setState(() => _selectedEntryId = previous.id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNodes[previous.id]?.requestFocus();
        final c = _controllers[previous.id];
        c?.selection = TextSelection.collapsed(offset: c.text.length);
      });
    }
  }

  /// Jump from a todo back to its source line on the board.
  void _revealEntry(Project project, Entry entry) {
    final projectIndex = store.projects.indexOf(project);
    setState(() {
      _todoExpanded = false;
      _selectedEntryId = entry.id;
    });
    if (projectIndex >= 0 && projectIndex != store.selectedIndex) {
      store.selectProject(projectIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = _focusNodes[entry.id];
      node?.requestFocus();
      final ctx = node?.context;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final project = store.selected;
        return Scaffold(
          body: Column(
            children: [
              _buildTitleBar(context),
              _buildProjectBar(context),
              const Divider(height: 1),
              if (!_todoExpanded)
                Expanded(
                  child: project == null
                      ? const SizedBox.shrink()
                      : _buildBoard(context, project),
                ),
              const Divider(height: 1),
              _buildTodoSection(context),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- title bar

  Widget _buildTitleBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 38,
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          // macOS keeps its native traffic lights with a hidden title bar.
          if (_isMac) const SizedBox(width: 72) else const SizedBox(width: 12),
          Expanded(
            child: DragToMoveArea(
              child: Text('Sticky Panel',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
            ),
          ),
          _titleBarIcon(
            _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
            _alwaysOnTop ? '取消置顶' : '窗口置顶',
            _toggleAlwaysOnTop,
            active: _alwaysOnTop,
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz,
                size: 18, color: scheme.onSurfaceVariant),
            tooltip: '更多',
            onSelected: (value) {
              if (value != 'clear_done') return;
              if (_todoShowAll) {
                for (final p in store.projects) {
                  store.clearDone(p);
                }
              } else {
                final project = store.selected;
                if (project != null) store.clearDone(project);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'clear_done',
                child: Text('清除已完成待办', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          if (!_isMac) ...[
            _titleBarIcon(Icons.minimize, '最小化', windowManager.minimize),
            _titleBarIcon(Icons.close, '关闭', windowManager.close),
          ],
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _titleBarIcon(IconData icon, String tooltip, VoidCallback onPressed,
      {bool active = false}) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon,
          size: 17, color: active ? scheme.primary : scheme.onSurfaceVariant),
      onPressed: onPressed,
    );
  }

  // -------------------------------------------------------------- project bar

  Widget _buildProjectBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: store.projects.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final project = store.projects[index];
                final selected = index == store.selectedIndex;
                return Center(
                  child: GestureDetector(
                    onTap: () {
                      store.selectProject(index);
                      setState(() => _selectedEntryId = null);
                    },
                    onLongPress: () => _showProjectMenu(context, project),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: selected
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Text(
                        project.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: selected
                              ? Colors.white
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: '新建项目',
            icon: Icon(Icons.add, size: 19, color: scheme.onSurfaceVariant),
            onPressed: () => _editProjectName(context, null),
          ),
        ],
      ),
    );
  }

  void _showProjectMenu(BuildContext context, Project project) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined),
              title: Text('重命名「${project.name}」'),
              onTap: () {
                Navigator.pop(context);
                _editProjectName(context, project);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text('删除「${project.name}」',
                  style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                store.deleteProject(project);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editProjectName(BuildContext context, Project? project) async {
    final controller = TextEditingController(text: project?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(project == null ? '新建项目' : '重命名项目',
            style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '项目名称'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (project == null) {
      store.addProject(result);
    } else {
      store.renameProject(project, result);
    }
  }

  // -------------------------------------------------------------------- board

  TextStyle _entryStyle(Entry entry, ColorScheme scheme) {
    final crossed = entry.isTodo && entry.done;
    return TextStyle(
      fontSize: entry.isHeading && entry.fontSize < 17 ? 18 : entry.fontSize,
      fontWeight:
          entry.bold || entry.isHeading ? FontWeight.w600 : FontWeight.normal,
      decoration: crossed ? TextDecoration.lineThrough : null,
      color: crossed ? scheme.onSurfaceVariant : scheme.onSurface,
      height: 1.4,
    );
  }

  Widget _buildBoard(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
    if (project.entries.isEmpty) {
      return Center(
        child: GestureDetector(
          onTap: () => _insertLineBelow(project, null),
          child: Text(
            '点这里开始写\n回车开新行，行首输入「# 」变标题',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      itemCount: project.entries.length,
      onReorderItem: (oldIndex, newIndex) =>
          store.reorderEntry(project, oldIndex, newIndex),
      footer: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: GestureDetector(
          onTap: () => _insertLineBelow(
              project, project.entries.isEmpty ? null : project.entries.last),
          child: Row(
            children: [
              Icon(Icons.add, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('添加一行',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
      itemBuilder: (context, index) {
        final entry = project.entries[index];
        return _buildBoardLine(context, project, entry, key: ValueKey(entry.id));
      },
    );
  }

  Widget _buildBoardLine(BuildContext context, Project project, Entry entry,
      {required Key key}) {
    final scheme = Theme.of(context).colorScheme;
    final selected = entry.id == _selectedEntryId;

    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (entry.isTodo)
              GestureDetector(
                onTap: () => store.toggleDone(entry),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    entry.done
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 17,
                    color: entry.done
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                  ),
                ),
              ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: entry.highlight == 0
                      ? (selected
                          ? scheme.surfaceContainerHighest
                              .withValues(alpha: 0.5)
                          : null)
                      : Color(entry.highlight),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: TextField(
                  controller: _controllerFor(entry),
                  focusNode: _focusNodeFor(project, entry),
                  style: _entryStyle(entry, scheme),
                  cursorColor: scheme.primary,
                  maxLines: null,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: entry.isHeading ? '标题' : null,
                    hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 5),
                  ),
                  onChanged: (text) => _onLineChanged(project, entry, text),
                  onSubmitted: (_) => _insertLineBelow(project, entry),
                ),
              ),
            ),
          ],
        ),
        if (selected) _buildLineToolbar(context, project, entry),
      ],
    );
  }

  void _onLineChanged(Project project, Entry entry, String text) {
    // Markdown shortcut: a line starting with "# " becomes a heading.
    if (!entry.isHeading && text.startsWith('# ')) {
      final stripped = text.substring(2);
      entry.text = stripped;
      final controller = _controllers[entry.id];
      controller?.value = TextEditingValue(
        text: stripped,
        selection: TextSelection.collapsed(offset: stripped.length),
      );
      store.setHeading(entry, true);
      return;
    }
    entry.text = text;
    store.persist();
  }

  Widget _buildLineToolbar(
      BuildContext context, Project project, Entry entry) {
    final scheme = Theme.of(context).colorScheme;
    final sizeIndex =
        kFontSizes.indexWhere((s) => (s - entry.fontSize).abs() < 0.1);

    Widget iconBtn(IconData icon, String tooltip, VoidCallback onPressed,
        {bool active = false}) {
      return IconButton(
        icon: Icon(icon, size: 17),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        color: active ? scheme.primary : scheme.onSurfaceVariant,
        onPressed: onPressed,
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          iconBtn(
            entry.isTodo ? Icons.check_circle : Icons.check_circle_outline,
            entry.isTodo ? '取消待办' : '拉出为待办',
            () => store.toggleEntryKind(entry),
            active: entry.isTodo,
          ),
          iconBtn(
            Icons.title,
            entry.isHeading ? '取消标题' : '设为标题',
            () => store.setHeading(entry, !entry.isHeading),
            active: entry.isHeading,
          ),
          iconBtn(Icons.format_bold, '加粗', () => store.toggleBold(entry),
              active: entry.bold),
          for (final color in kHighlightColors)
            GestureDetector(
              onTap: () => store.setHighlight(entry, color.toARGB32()),
              child: Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: color.toARGB32() == 0
                      ? scheme.surface
                      : color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: entry.highlight == color.toARGB32()
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: entry.highlight == color.toARGB32() ? 2 : 1,
                  ),
                ),
                child: color.toARGB32() == 0
                    ? Icon(Icons.block,
                        size: 11, color: scheme.onSurfaceVariant)
                    : null,
              ),
            ),
          iconBtn(
            Icons.format_size,
            '字号：${entry.fontSize.toInt()}（点击切换）',
            () {
              final next = kFontSizes[(sizeIndex + 1) % kFontSizes.length];
              store.setFontSize(entry, next);
            },
          ),
          Text('${entry.fontSize.toInt()}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          iconBtn(Icons.delete_outline, '删除此行',
              () => _removeLine(project, entry)),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- todo panel

  /// Todos of one project, grouped by the heading they were pulled from.
  /// Dart maps preserve insertion order, so groups follow board order.
  Map<String, List<Entry>> _todoGroupsFor(Project project) {
    final groups = <String, List<Entry>>{};
    String section = '未分组';
    for (final e in project.entries) {
      if (e.isHeading) section = e.text.isEmpty ? '未命名段落' : e.text;
      if (e.isTodo) groups.putIfAbsent(section, () => []).add(e);
    }
    return groups;
  }

  Widget _buildTodoSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final project = store.selected;

    // Groups of (header label, project, todos) depending on the scope.
    final groups = <({String label, Project project, List<Entry> todos})>[];
    if (_todoShowAll) {
      for (final p in store.projects) {
        final todos = p.entries.where((e) => e.isTodo).toList();
        if (todos.isNotEmpty) {
          groups.add((label: p.name, project: p, todos: todos));
        }
      }
    } else if (project != null) {
      for (final entry in _todoGroupsFor(project).entries) {
        groups
            .add((label: entry.key, project: project, todos: entry.value));
      }
    }

    final total = groups.fold<int>(0, (sum, g) => sum + g.todos.length);
    final remaining = groups.fold<int>(
        0, (sum, g) => sum + g.todos.where((e) => !e.done).length);

    final list = groups.isEmpty
        ? Center(
            child: Text('在编辑板里把某行「拉出为待办」，会汇总到这里',
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            children: [
              for (final group in groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Text(
                    group.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final todo in group.todos)
                  _buildTodoTile(context, group.project, todo),
              ],
            ],
          );

    final content = Column(
      children: [
        _buildTodoHeader(context, remaining, total),
        Expanded(child: list),
      ],
    );

    return _todoExpanded
        ? Expanded(
            child: Container(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              child: content,
            ),
          )
        : Container(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            height: 180,
            child: content,
          );
  }

  Widget _buildTodoHeader(BuildContext context, int remaining, int total) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Text('待办',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(width: 6),
          Text('剩余 $remaining / 共 $total',
              style:
                  TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          if (store.projects.length > 1) ...[
            const SizedBox(width: 10),
            _buildScopeToggle(context),
          ],
          const Spacer(),
          IconButton(
            tooltip: _todoExpanded ? '收起待办区' : '待办区占满面板',
            icon: Icon(
              _todoExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () =>
                setState(() => _todoExpanded = !_todoExpanded),
          ),
        ],
      ),
    );
  }

  Widget _buildScopeToggle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String label, bool active, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: active ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: active ? Colors.white : scheme.onSurfaceVariant)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pill('本项目', !_todoShowAll,
              () => setState(() => _todoShowAll = false)),
          pill('全部', _todoShowAll,
              () => setState(() => _todoShowAll = true)),
        ],
      ),
    );
  }

  Widget _buildTodoTile(BuildContext context, Project project, Entry todo) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => store.toggleDone(todo),
            child: Icon(
              todo.done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 17,
              color: todo.done ? scheme.onSurfaceVariant : scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => _revealEntry(project, todo),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: BoxDecoration(
                  color: todo.highlight == 0 ? null : Color(todo.highlight),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  todo.text,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        todo.bold ? FontWeight.w600 : FontWeight.normal,
                    decoration:
                        todo.done ? TextDecoration.lineThrough : null,
                    color: todo.done
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
