import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'store.dart';

/// Highlight palette (ARGB, semi-opaque so it reads on both light and dark).
const List<Color> kHighlightColors = [
  Color(0x00000000), // none
  Color(0x66FFD54F), // yellow
  Color(0x66A5D6A7), // green
  Color(0x6690CAF9), // blue
  Color(0x66F48FB1), // pink
  Color(0x66FFAB91), // orange
];

/// Font size presets cycled by the size button.
const List<double> kFontSizes = [13, 15, 18, 22];

class StickyPanelApp extends StatelessWidget {
  const StickyPanelApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final seed = Colors.amber;
    return MaterialApp(
      title: 'Sticky Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
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
  bool _alwaysOnTop = true;
  bool _addAsTodo = false;
  String? _selectedEntryId;

  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();

  AppStore get store => widget.store;

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    setState(() {});
  }

  void _submitInput() {
    final project = store.selected;
    final text = _inputController.text.trim();
    if (project == null || text.isEmpty) return;
    final entry = store.addEntry(project, text, isTodo: _addAsTodo);
    _inputController.clear();
    setState(() => _selectedEntryId = entry.id);
    _inputFocus.requestFocus();
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
              Expanded(
                child: project == null
                    ? const SizedBox.shrink()
                    : _buildEntryList(context, project),
              ),
              const Divider(height: 1),
              _buildInputBar(context),
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
      height: 40,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(Icons.sticky_note_2_outlined, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text('Sticky Panel',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: _alwaysOnTop ? '取消置顶' : '窗口置顶',
            icon: Icon(
              _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
              size: 18,
              color: _alwaysOnTop ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: _toggleAlwaysOnTop,
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 18, color: scheme.onSurfaceVariant),
            tooltip: '更多',
            onSelected: (value) {
              final project = store.selected;
              if (value == 'clear_done' && project != null) store.clearDone(project);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'clear_done', child: Text('清除已完成待办')),
            ],
          ),
          IconButton(
            tooltip: '最小化',
            icon: Icon(Icons.minimize, size: 18, color: scheme.onSurfaceVariant),
            onPressed: () => windowManager.minimize(),
          ),
          IconButton(
            tooltip: '关闭',
            icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
            onPressed: () => windowManager.close(),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- project bar

  Widget _buildProjectBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: store.projects.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final project = store.projects[index];
                final selected = index == store.selectedIndex;
                return GestureDetector(
                  onLongPress: () => _showProjectMenu(context, project),
                  child: ChoiceChip(
                    label: Text(project.name, style: const TextStyle(fontSize: 12)),
                    selected: selected,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      store.selectProject(index);
                      setState(() => _selectedEntryId = null);
                    },
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: '新建项目',
            icon: Icon(Icons.add, size: 20, color: scheme.onSurfaceVariant),
            onPressed: () => _editProjectName(context, null),
          ),
        ],
      ),
    );
  }

  void _showProjectMenu(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
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
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除「${project.name}」', style: TextStyle(color: scheme.error)),
              onTap: () {
                Navigator.pop(context);
                store.deleteProject(project);
                setState(() => _selectedEntryId = null);
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
        title: Text(project == null ? '新建项目' : '重命名项目'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '项目名称'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
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

  // --------------------------------------------------------------- entry list

  Widget _buildEntryList(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
    if (project.entries.isEmpty) {
      return Center(
        child: Text(
          '还没有内容\n在下方输入一行，随手记下来',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      );
    }

    // Running number shown on todo lines only.
    var todoCount = 0;
    final todoNumbers = <String, int>{};
    for (final e in project.entries) {
      if (e.isTodo) todoNumbers[e.id] = ++todoCount;
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: project.entries.length,
      onReorderItem: (oldIndex, newIndex) =>
          store.reorderEntry(project, oldIndex, newIndex),
      itemBuilder: (context, index) {
        final entry = project.entries[index];
        return _EntryTile(
          key: ValueKey(entry.id),
          entry: entry,
          todoNumber: todoNumbers[entry.id],
          selected: entry.id == _selectedEntryId,
          onTap: () => setState(() => _selectedEntryId = entry.id),
          onToggleDone: () => store.toggleDone(entry),
          onCommitText: (text) {
            if (text.trim().isEmpty) {
              store.removeEntry(project, entry);
              setState(() => _selectedEntryId = null);
            } else {
              store.updateEntryText(entry, text.trim());
            }
          },
          toolbar: entry.id == _selectedEntryId
              ? _buildEntryToolbar(context, project, entry)
              : null,
        );
      },
    );
  }

  Widget _buildEntryToolbar(BuildContext context, Project project, Entry entry) {
    final scheme = Theme.of(context).colorScheme;
    final sizeIndex = kFontSizes.indexWhere((s) => (s - entry.fontSize).abs() < 0.1);

    Widget iconBtn(IconData icon, String tooltip, VoidCallback onPressed,
        {bool active = false}) {
      return IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        color: active ? scheme.primary : scheme.onSurfaceVariant,
        onPressed: onPressed,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 36, right: 8, bottom: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          iconBtn(
            entry.isTodo ? Icons.check_box : Icons.check_box_outline_blank,
            entry.isTodo ? '转为备忘' : '转为待办',
            () => store.toggleEntryKind(entry),
            active: entry.isTodo,
          ),
          iconBtn(Icons.format_bold, '加粗', () => store.toggleBold(entry),
              active: entry.bold),
          // Highlight swatches.
          for (final color in kHighlightColors)
            GestureDetector(
              onTap: () => store.setHighlight(entry, color.toARGB32()),
              child: Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: color.toARGB32() == 0 ? scheme.surfaceContainerHighest : color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: entry.highlight == color.toARGB32()
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: entry.highlight == color.toARGB32() ? 2 : 1,
                  ),
                ),
                child: color.toARGB32() == 0
                    ? Icon(Icons.block, size: 12, color: scheme.onSurfaceVariant)
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
              () {
                store.removeEntry(project, entry);
                setState(() => _selectedEntryId = null);
              }),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- input bar

  Widget _buildInputBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: _addAsTodo ? '新增为待办（点击切换）' : '新增为备忘（点击切换）',
            icon: Icon(
              _addAsTodo ? Icons.check_box : Icons.notes,
              size: 20,
              color: _addAsTodo ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: () => setState(() => _addAsTodo = !_addAsTodo),
          ),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _submitInput,
              },
              child: TextField(
                controller: _inputController,
                focusNode: _inputFocus,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: _addAsTodo ? '记一条待办…' : '随手记一行…',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                onSubmitted: (_) => _submitInput(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ entry row

class _EntryTile extends StatefulWidget {
  const _EntryTile({
    super.key,
    required this.entry,
    required this.todoNumber,
    required this.selected,
    required this.onTap,
    required this.onToggleDone,
    required this.onCommitText,
    this.toolbar,
  });

  final Entry entry;
  final int? todoNumber;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;
  final ValueChanged<String> onCommitText;
  final Widget? toolbar;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool _editing = false;
  late final TextEditingController _controller;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startEdit() {
    _controller.text = widget.entry.text;
    setState(() => _editing = true);
    _focusNode.requestFocus();
  }

  void _commit() {
    if (!_editing) return;
    setState(() => _editing = false);
    widget.onCommitText(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = widget.entry;

    final textStyle = TextStyle(
      fontSize: entry.fontSize,
      fontWeight: entry.bold ? FontWeight.bold : FontWeight.normal,
      decoration: entry.isTodo && entry.done ? TextDecoration.lineThrough : null,
      color: entry.isTodo && entry.done ? scheme.onSurfaceVariant : scheme.onSurface,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Leading marker: checkbox for todos, bullet for notes.
              SizedBox(
                width: 32,
                child: entry.isTodo
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: Checkbox(
                              value: entry.done,
                              visualDensity: VisualDensity.compact,
                              onChanged: (_) => widget.onToggleDone(),
                            ),
                          ),
                          if (widget.todoNumber != null)
                            Text('${widget.todoNumber}',
                                style: TextStyle(
                                    fontSize: 10, color: scheme.onSurfaceVariant)),
                        ],
                      )
                    : Center(
                        child: Icon(Icons.circle,
                            size: 5, color: scheme.onSurfaceVariant),
                      ),
              ),
              Expanded(
                child: _editing
                    ? TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        style: textStyle,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                        ),
                        onSubmitted: (_) => _commit(),
                        onTapOutside: (_) => _commit(),
                      )
                    : GestureDetector(
                        onTap: () {
                          if (widget.selected) {
                            _startEdit();
                          } else {
                            widget.onTap();
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 3),
                          decoration: BoxDecoration(
                            color: entry.highlight == 0
                                ? (widget.selected
                                    ? scheme.surfaceContainerHighest
                                        .withValues(alpha: 0.4)
                                    : null)
                                : Color(entry.highlight),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(entry.text, style: textStyle),
                        ),
                      ),
              ),
            ],
          ),
        ),
        if (widget.toolbar != null) widget.toolbar!,
      ],
    );
  }
}
