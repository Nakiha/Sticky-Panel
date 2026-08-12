import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'store.dart';
import 'todos.dart';

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
      localizationsDelegates: const [
        FlutterQuillLocalizations.delegate,
      ],
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

  /// Shared by the editor across projects; the editor widget itself is
  /// keyed by project id, so swapping controllers stays safe.
  final _editorFocusNode = FocusNode();
  final _editorScrollController = ScrollController();

  AppStore get store => widget.store;

  @override
  void dispose() {
    _editorFocusNode.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    setState(() {});
  }

  /// Jump from a todo back to its source span in the editor.
  void _revealSpan(Project project, TodoSpan span) {
    final projectIndex = store.projects.indexOf(project);
    setState(() => _todoExpanded = false);
    if (projectIndex >= 0 && projectIndex != store.selectedIndex) {
      store.selectProject(projectIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editorFocusNode.requestFocus();
      final controller = store.controllerFor(project);
      controller.updateSelection(
        TextSelection(
            baseOffset: span.start, extentOffset: span.start + span.length),
        ChangeSource.local,
      );
      // Best effort: nudge the selection into view once layout settles.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_editorScrollController.hasClients) {
          _editorScrollController.animateTo(
            _editorScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
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
              if (!_todoExpanded && project != null) ...[
                Expanded(child: _buildEditor(context, project)),
                const Divider(height: 1),
              ],
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
                    onTap: () => store.selectProject(index),
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

  // ------------------------------------------------------------ quill editor

  /// Highlight choices in the selection panel: quill color string + swatch.
  static const _highlights = <(String?, Color)>[
    (null, Colors.transparent),
    ('rgba(255,213,79,0.55)', Color(0xFFFFD54F)),
    ('rgba(165,214,167,0.55)', Color(0xFFA5D6A7)),
    ('rgba(144,202,249,0.55)', Color(0xFF90CAF9)),
    ('rgba(244,143,177,0.55)', Color(0xFFF48FB1)),
    ('rgba(255,171,145,0.55)', Color(0xFFFFAB91)),
  ];

  static const _fontSizes = ['13', '15', '18', '22'];

  Widget _buildEditor(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
    // Quill derives its base text style from the ambient DefaultTextStyle,
    // so this keeps the document readable in both light and dark mode.
    return Stack(
      children: [
        DefaultTextStyle(
          style: TextStyle(fontSize: 14, height: 1.4, color: scheme.onSurface),
          child: QuillEditor(
            key: ValueKey(project.id),
            controller: store.controllerFor(project),
            focusNode: _editorFocusNode,
            scrollController: _editorScrollController,
            config: QuillEditorConfig(
              placeholder: '随手记…',
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              expands: true,
              // The todo underline is derived from the custom `todo`
              // attribute instead of a stored underline attribute, so the
              // visual marker can never leak into neighbouring text.
              customStyleBuilder: (attribute) {
                if (attribute.key != kTodoAttributeKey) {
                  return const TextStyle();
                }
                final done = attribute.value == 'done';
                return TextStyle(
                  decoration: done
                      ? TextDecoration.lineThrough
                      : TextDecoration.underline,
                  decorationColor: scheme.primary,
                  color: done ? scheme.onSurfaceVariant : null,
                );
              },
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 8,
          child: _buildSelectionPanel(context, project),
        ),
      ],
    );
  }

  /// Floating rich-text mini panel that appears while text is selected.
  Widget _buildSelectionPanel(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
    final controller = store.controllerFor(project);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final selection = controller.selection;
        final visible = selection.isValid && !selection.isCollapsed;
        final attrs = controller.getSelectionStyle().attributes;

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

        final sizeValue = attrs['size']?.value?.toString();
        final background = attrs['background']?.value?.toString();
        final isTodo = attrs.containsKey(kTodoAttributeKey);

        final panel = Material(
          color: scheme.surfaceContainerHighest,
          elevation: 0,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconBtn(Icons.format_bold, '加粗', () {
                  controller.formatSelection(Attribute.bold);
                  _editorFocusNode.requestFocus();
                }, active: attrs.containsKey('bold')),
                iconBtn(Icons.title, '标题', () {
                  final active = attrs['header'] != null;
                  controller.formatSelection(
                      Attribute.clone(Attribute.header, active ? null : 2));
                  _editorFocusNode.requestFocus();
                }, active: attrs['header'] != null),
                iconBtn(Icons.format_size, '字号：${sizeValue ?? '默认'}（点击切换）',
                    () {
                  final index = _fontSizes.indexOf(sizeValue ?? '');
                  final next = _fontSizes[(index + 1) % _fontSizes.length];
                  controller.formatSelection(
                      Attribute.clone(Attribute.size, next));
                  _editorFocusNode.requestFocus();
                }, active: sizeValue != null),
                if (sizeValue != null)
                  Text(sizeValue,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 4),
                for (final (value, swatch) in _highlights)
                  GestureDetector(
                    onTap: () {
                      controller.formatSelection(
                          Attribute.clone(Attribute.background, value));
                      _editorFocusNode.requestFocus();
                    },
                    child: Container(
                      width: 18,
                      height: 18,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: value == null ? scheme.surface : swatch,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: background == value
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: background == value ? 2 : 1,
                        ),
                      ),
                      child: value == null
                          ? Icon(Icons.block,
                              size: 11, color: scheme.onSurfaceVariant)
                          : null,
                    ),
                  ),
                const SizedBox(width: 4),
                iconBtn(
                  isTodo ? Icons.task_alt : Icons.playlist_add_check,
                  isTodo ? '取消待办' : '列为待办',
                  visible
                      ? () {
                          final start = selection.start;
                          final length = selection.end - selection.start;
                          if (isTodo) {
                            store.unmarkTodoSpan(project, start, length);
                          } else {
                            store.markTodoSpan(project, start, length);
                          }
                          _editorFocusNode.requestFocus();
                        }
                      : () {},
                  active: isTodo,
                ),
              ],
            ),
          ),
        );

        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: panel,
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------- todo panel

  /// Todo spans of one project, grouped by their section (nearest heading).
  Map<String, List<TodoSpan>> _todoGroupsFor(Project project) {
    final ops = store.controllerFor(project).document.toDelta().toJson();
    final groups = <String, List<TodoSpan>>{};
    for (final span in parseTodoSpans(ops)) {
      groups.putIfAbsent(span.section, () => []).add(span);
    }
    return groups;
  }

  Widget _buildTodoSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final project = store.selected;

    // Groups of (header label, project, todos) depending on the scope.
    final groups = <({String label, Project project, List<TodoSpan> todos})>[];
    if (_todoShowAll) {
      for (final p in store.projects) {
        final todos = [
          for (final group in _todoGroupsFor(p).entries) ...group.value,
        ];
        if (todos.isNotEmpty) {
          groups.add((label: p.name, project: p, todos: todos));
        }
      }
    } else if (project != null) {
      for (final group in _todoGroupsFor(project).entries) {
        groups.add((label: group.key, project: project, todos: group.value));
      }
    }

    final total = groups.fold<int>(0, (sum, g) => sum + g.todos.length);
    final remaining = groups.fold<int>(
        0, (sum, g) => sum + g.todos.where((e) => !e.done).length);

    final list = groups.isEmpty
        ? Center(
            child: Text('在编辑板里划选一段文字，点浮动面板的 ☑ 列为待办',
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

  Widget _buildTodoTile(BuildContext context, Project project, TodoSpan todo) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => store.toggleSpanDone(project, todo),
            child: Icon(
              todo.done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 17,
              color: todo.done ? scheme.onSurfaceVariant : scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => _revealSpan(project, todo),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  todo.text,
                  style: TextStyle(
                    fontSize: 14,
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
