import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'store.dart';

/// Sticky-note palette. The app intentionally ignores the system theme:
/// it looks like a paper sticky note everywhere.
class StickyColors {
  static const paper = Color(0xFFFCEFA8);
  static const paperDeep = Color(0xFFF5E086);
  static const ink = Color(0xFF4A3F1F);
  static const inkSoft = Color(0xFF8A7B52);
  static const line = Color(0x334A3F1F);
  static const selection = Color(0x1F4A3F1F);
}

/// Highlight palette (marker-style, semi-opaque over the paper color).
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
    return MaterialApp(
      title: 'Sticky Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: StickyColors.paper,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        dividerTheme:
            const DividerThemeData(color: StickyColors.line, thickness: 1),
        dialogTheme:
            const DialogThemeData(backgroundColor: StickyColors.paper),
        bottomSheetTheme: const BottomSheetThemeData(
            backgroundColor: StickyColors.paper),
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
    return Container(
      height: 38,
      color: StickyColors.paperDeep,
      child: Row(
        children: [
          // macOS keeps its native traffic-light buttons even with a hidden
          // title bar — leave room for them and don't draw our own controls.
          if (_isMac) const SizedBox(width: 72),
          Expanded(
            child: DragToMoveArea(
              child: Row(
                children: [
                  if (!_isMac) ...[
                    const SizedBox(width: 10),
                    const Icon(Icons.sticky_note_2_outlined,
                        size: 15, color: StickyColors.inkSoft),
                    const SizedBox(width: 6),
                  ],
                  const Text('Sticky Panel',
                      style: TextStyle(
                          fontSize: 12,
                          color: StickyColors.inkSoft,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          _titleBarIcon(
            _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
            _alwaysOnTop ? '取消置顶' : '窗口置顶',
            _toggleAlwaysOnTop,
            active: _alwaysOnTop,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                size: 17, color: StickyColors.inkSoft),
            tooltip: '更多',
            color: StickyColors.paper,
            onSelected: (value) {
              final project = store.selected;
              if (value == 'clear_done' && project != null) {
                store.clearDone(project);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'clear_done',
                child: Text('清除已完成待办',
                    style: TextStyle(fontSize: 13, color: StickyColors.ink)),
              ),
            ],
          ),
          // Windows has no native controls with a hidden title bar.
          if (!_isMac) ...[
            _titleBarIcon(Icons.minimize, '最小化', windowManager.minimize),
            _titleBarIcon(Icons.close, '关闭', windowManager.close),
            const SizedBox(width: 4),
          ] else
            const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _titleBarIcon(IconData icon, String tooltip, VoidCallback onPressed,
      {bool active = false}) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon,
          size: 17, color: active ? StickyColors.ink : StickyColors.inkSoft),
      onPressed: onPressed,
    );
  }

  // -------------------------------------------------------------- project bar

  Widget _buildProjectBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 10),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: store.projects.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
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
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: selected ? StickyColors.ink : Colors.transparent,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: selected
                              ? StickyColors.ink
                              : StickyColors.line,
                        ),
                      ),
                      child: Text(
                        project.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: selected
                              ? StickyColors.paper
                              : StickyColors.ink,
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
            icon: const Icon(Icons.add, size: 19, color: StickyColors.inkSoft),
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
              leading:
                  const Icon(Icons.edit_outlined, color: StickyColors.ink),
              title: Text('重命名「${project.name}」',
                  style: const TextStyle(color: StickyColors.ink)),
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
        title: Text(project == null ? '新建项目' : '重命名项目',
            style: const TextStyle(fontSize: 15, color: StickyColors.ink)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: StickyColors.ink),
          decoration: const InputDecoration(
            hintText: '项目名称',
            hintStyle: TextStyle(color: StickyColors.inkSoft),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: StickyColors.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定',
                style: TextStyle(
                    color: StickyColors.ink, fontWeight: FontWeight.bold)),
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
    if (project.entries.isEmpty) {
      return const Center(
        child: Text(
          '还没有内容\n在下方输入一行，随手记下来',
          textAlign: TextAlign.center,
          style: TextStyle(color: StickyColors.inkSoft, fontSize: 13),
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
    final sizeIndex = kFontSizes.indexWhere((s) => (s - entry.fontSize).abs() < 0.1);

    Widget iconBtn(IconData icon, String tooltip, VoidCallback onPressed,
        {bool active = false}) {
      return IconButton(
        icon: Icon(icon, size: 17),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        color: active ? StickyColors.ink : StickyColors.inkSoft,
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
                width: 18,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: color.toARGB32() == 0 ? StickyColors.paper : color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: entry.highlight == color.toARGB32()
                        ? StickyColors.ink
                        : StickyColors.line,
                    width: entry.highlight == color.toARGB32() ? 2 : 1,
                  ),
                ),
                child: color.toARGB32() == 0
                    ? const Icon(Icons.block,
                        size: 11, color: StickyColors.inkSoft)
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
              style:
                  const TextStyle(fontSize: 11, color: StickyColors.inkSoft)),
          iconBtn(Icons.delete_outline, '删除此行', () {
            store.removeEntry(project, entry);
            setState(() => _selectedEntryId = null);
          }),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- input bar

  Widget _buildInputBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: _addAsTodo ? '新增为待办（点击切换）' : '新增为备忘（点击切换）',
            icon: Icon(
              _addAsTodo ? Icons.check_box : Icons.notes,
              size: 19,
              color: _addAsTodo ? StickyColors.ink : StickyColors.inkSoft,
            ),
            onPressed: () => setState(() => _addAsTodo = !_addAsTodo),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: StickyColors.line),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): _submitInput,
                },
                child: TextField(
                  controller: _inputController,
                  focusNode: _inputFocus,
                  style: const TextStyle(
                      fontSize: 14, color: StickyColors.ink),
                  cursorColor: StickyColors.ink,
                  decoration: InputDecoration(
                    hintText: _addAsTodo ? '记一条待办…' : '随手记一行…',
                    hintStyle: const TextStyle(color: StickyColors.inkSoft),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 9),
                  ),
                  onSubmitted: (_) => _submitInput(),
                ),
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
    final entry = widget.entry;

    final textStyle = TextStyle(
      fontSize: entry.fontSize,
      fontWeight: entry.bold ? FontWeight.bold : FontWeight.normal,
      decoration: entry.isTodo && entry.done ? TextDecoration.lineThrough : null,
      color: entry.isTodo && entry.done
          ? StickyColors.inkSoft
          : StickyColors.ink,
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
                          GestureDetector(
                            onTap: widget.onToggleDone,
                            child: Icon(
                              entry.done
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              size: 17,
                              color: entry.done
                                  ? StickyColors.inkSoft
                                  : StickyColors.ink,
                            ),
                          ),
                          if (widget.todoNumber != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 2),
                              child: Text('${widget.todoNumber}',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: StickyColors.inkSoft)),
                            ),
                        ],
                      )
                    : const Center(
                        child: Icon(Icons.circle,
                            size: 5, color: StickyColors.inkSoft),
                      ),
              ),
              Expanded(
                child: _editing
                    ? TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        style: textStyle,
                        cursorColor: StickyColors.ink,
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
                                    ? StickyColors.selection
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
