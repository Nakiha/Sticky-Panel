import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'store.dart';
import 'todos.dart';
import 'widgets/app_menu_combo.dart';

typedef _TodoGroup = ({String label, Project project, List<TodoSpan> todos});
typedef _TodoTileIdentity = ({
  String projectId,
  String section,
  String text,
  int occurrence,
});
typedef _KeyedTodo = ({TodoSpan todo, _TodoTileIdentity key});

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
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
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

class _HomePageState extends State<HomePage> with WindowListener {
  static final bool _isMac = defaultTargetPlatform == TargetPlatform.macOS;
  static const double _todoHeaderHeight = 40;
  static const double _defaultTodoPanelHeight = 180;
  static const double _todoTextSize = 14;
  static const Locale _editorLocale = Locale('zh', 'CN');
  static const List<String> _editorFontFallbacks = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
  ];
  static const Duration _panelMotion = Duration(milliseconds: 240);
  static const Duration _todoMotion = Duration(milliseconds: 180);

  bool _alwaysOnTop = true;
  bool _todoExpanded = false;
  bool _todoShowAll = false;
  bool _todoHeaderHovered = false;
  bool _resizingTodoPanel = false;
  bool _closeDialogOpen = false;
  bool _clearingDone = false;
  double _todoPanelHeight = _defaultTodoPanelHeight;
  double _todoHeightBeforeExpand = _defaultTodoPanelHeight;
  final Set<_TodoTileIdentity> _dismissingTodos = {};

  /// One focus node / scroll controller per project: all editors stay alive
  /// in an IndexedStack, so sharing a single ScrollController would attach
  /// it to multiple scroll views and throw on every tab switch.
  final _editorFocusNodes = <String, FocusNode>{};
  final _editorScrollControllers = <String, ScrollController>{};
  final _selectionPanelAnchors = <String, ValueNotifier<Offset?>>{};

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_pruneEditorAttachments);
    windowManager.addListener(this);
  }

  FocusNode _focusFor(Project project) =>
      _editorFocusNodes.putIfAbsent(project.id, FocusNode.new);

  ScrollController _scrollFor(Project project) =>
      _editorScrollControllers.putIfAbsent(project.id, ScrollController.new);

  ValueNotifier<Offset?> _selectionAnchorFor(Project project) =>
      _selectionPanelAnchors.putIfAbsent(
        project.id,
        () => ValueNotifier<Offset?>(null),
      );

  void _pruneEditorAttachments() {
    final live = store.projects.map((p) => p.id).toSet();
    for (final id
        in _editorFocusNodes.keys.where((id) => !live.contains(id)).toList()) {
      _editorFocusNodes.remove(id)?.dispose();
    }
    for (final id in _editorScrollControllers.keys
        .where((id) => !live.contains(id))
        .toList()) {
      _editorScrollControllers.remove(id)?.dispose();
    }
    for (final id in _selectionPanelAnchors.keys
        .where((id) => !live.contains(id))
        .toList()) {
      _selectionPanelAnchors.remove(id)?.dispose();
    }
    _editorCache.removeWhere((key, _) => !live.contains(key.split('|').first));
  }

  @override
  void dispose() {
    store.removeListener(_pruneEditorAttachments);
    windowManager.removeListener(this);
    for (final node in _editorFocusNodes.values) {
      node.dispose();
    }
    for (final controller in _editorScrollControllers.values) {
      controller.dispose();
    }
    for (final anchor in _selectionPanelAnchors.values) {
      anchor.dispose();
    }
    super.dispose();
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    setState(() {});
  }

  @override
  void onWindowClose() {
    _requestClose();
  }

  Future<void> _requestClose() async {
    if (_closeDialogOpen || !mounted) return;
    _closeDialogOpen = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('关闭 Sticky Panel', style: TextStyle(fontSize: 15)),
          content: const Text('确定要关闭吗？所有内容都已自动保存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('关闭', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      // Destroying the native window from inside the guarded WM_CLOSE
      // callback can block Windows' platform thread. Release the guard first,
      // let the dialog route complete this frame, then request a normal close.
      await windowManager.setPreventClose(false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(windowManager.close());
      });
    } finally {
      _closeDialogOpen = false;
    }
  }

  /// Jump from a todo back to its source span in the editor.
  void _revealSpan(Project project, TodoSpan span) {
    final projectIndex = store.projects.indexOf(project);
    setState(() {
      if (_todoExpanded) {
        _todoExpanded = false;
        _todoPanelHeight = _todoHeightBeforeExpand;
      }
    });
    if (projectIndex >= 0 && projectIndex != store.selectedIndex) {
      store.selectProject(projectIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusFor(project).requestFocus();
      final controller = store.controllerFor(project);
      controller.updateSelection(
        TextSelection(
          baseOffset: span.start,
          extentOffset: span.start + span.length,
        ),
        ChangeSource.local,
      );
      // Best effort: nudge the selection into view once layout settles.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final scroll = _scrollFor(project);
        if (scroll.hasClients) {
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final perfWatch = Stopwatch()..start();
    final built = AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final project = store.selected;
        // Per-project theme color: override the accent for everything below.
        final base = Theme.of(context);
        final scheme = project == null || project.colorValue == 0
            ? base.colorScheme
            : base.colorScheme.copyWith(primary: Color(project.colorValue));
        return Theme(
          data: base.copyWith(colorScheme: scheme),
          child: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  _buildTopBar(context),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => _buildWorkspace(
                        context,
                        project,
                        constraints.maxHeight,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (perfWatch.elapsedMilliseconds > 8) {
      debugPrint('[perf] page build: ${perfWatch.elapsedMilliseconds}ms');
    }
    return built;
  }

  Widget _buildWorkspace(
    BuildContext context,
    Project? project,
    double availableHeight,
  ) {
    final maxTodoHeight = availableHeight < _todoHeaderHeight
        ? _todoHeaderHeight
        : availableHeight;
    final requestedHeight = _todoExpanded ? maxTodoHeight : _todoPanelHeight;
    final todoHeight =
        requestedHeight.clamp(_todoHeaderHeight, maxTodoHeight).toDouble();

    return Column(
      children: [
        if (project != null)
          Expanded(
            child: IndexedStack(
              index: store.selectedIndex,
              children: [
                for (final p in store.projects) _editorFor(context, p),
              ],
            ),
          )
        else
          const Spacer(),
        AnimatedContainer(
          key: const ValueKey('todo-panel'),
          duration: _resizingTodoPanel ? Duration.zero : _panelMotion,
          curve: Curves.easeInOutCubic,
          height: todoHeight,
          child: _buildTodoSection(context, maxTodoHeight),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ top bar

  /// Chrome-style tab strip: full-height tabs flush with the content below,
  /// a trailing "+" tab, and only the pin button on the right. The whole
  /// strip is draggable.
  Widget _buildTopBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      color: scheme.surfaceContainerHighest,
      // Custom drag area: window_manager's DragToMoveArea hardcodes a
      // double-tap-to-maximize gesture, which also fired when clicking
      // through tabs quickly. Maximize is left to the native controls.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startDragging(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // macOS keeps its native traffic lights with a hidden title bar.
            if (_isMac) const SizedBox(width: 72) else const SizedBox(width: 8),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: store.projects.length,
                separatorBuilder: (_, _) => const SizedBox(width: 2),
                itemBuilder: (context, index) =>
                    _buildTab(context, store.projects[index], index),
              ),
            ),
            IconButton(
              tooltip: '新建项目',
              icon: Icon(Icons.add, size: 17, color: scheme.onSurfaceVariant),
              onPressed: () => _editProjectName(context, null),
            ),
            _titleBarIcon(
              _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
              _alwaysOnTop ? '取消置顶' : '窗口置顶',
              _toggleAlwaysOnTop,
              active: _alwaysOnTop,
            ),
            if (!_isMac) ...[
              _titleBarIcon(Icons.minimize, '最小化', windowManager.minimize),
              _titleBarIcon(Icons.close, '关闭', _requestClose, danger: true),
            ],
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(BuildContext context, Project project, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = index == store.selectedIndex;
    final projectColor =
        project.colorValue == 0 ? null : Color(project.colorValue);
    return _ProjectTab(
      selected: selected,
      projectColor: projectColor,
      name: project.name,
      textColor: selected ? scheme.onSurface : scheme.onSurfaceVariant,
      surfaceColor: scheme.surface,
      // Switch on pointer DOWN (like browser tabs and like the instant
      // ripple of the + button) instead of waiting for pointer-up.
      onPressed: () {
        final sw = Stopwatch()..start();
        store.selectProject(index);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          debugPrint('[perf] press->frame: ${sw.elapsedMilliseconds}ms');
        });
      },
      onLongPress: () => _showProjectMenu(context, project),
    );
  }

  Widget _titleBarIcon(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    bool active = false,
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 17),
      style: ButtonStyle(
        fixedSize: const WidgetStatePropertyAll(Size(40, 36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        animationDuration: const Duration(milliseconds: 140),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (danger && _isDangerButtonActive(states)) {
            return scheme.error;
          }
          return active ? scheme.primary : scheme.onSurfaceVariant;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (!danger) return Colors.transparent;
          if (states.contains(WidgetState.pressed)) {
            return scheme.error.withValues(alpha: 0.18);
          }
          if (_isDangerButtonActive(states)) {
            return scheme.error.withValues(alpha: 0.12);
          }
          return Colors.transparent;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      onPressed: onPressed,
    );
  }

  bool _isDangerButtonActive(Set<WidgetState> states) =>
      states.contains(WidgetState.hovered) ||
      states.contains(WidgetState.focused) ||
      states.contains(WidgetState.pressed);

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
              leading: const Icon(Icons.palette_outlined),
              title: const Text('主题色'),
              onTap: () {
                Navigator.pop(context);
                _pickProjectColor(context, project);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                '删除「${project.name}」',
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteProject(context, project);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Project theme color choices: 0 = default blue, then Apple accents.
  static const _projectColors = <(int, String)>[
    (0, '默认蓝'),
    (0xFF34C759, '绿'),
    (0xFFFF9500, '橙'),
    (0xFFFF3B30, '红'),
    (0xFFAF52DE, '紫'),
    (0xFFFF2D55, '粉'),
    (0xFF30B0C7, '青'),
  ];

  Future<void> _pickProjectColor(BuildContext context, Project project) async {
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('项目主题色', style: TextStyle(fontSize: 15)),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (value, label) in _projectColors)
              GestureDetector(
                onTap: () {
                  store.setProjectColor(project, value);
                  Navigator.pop(context);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: value == 0 ? scheme.primary : Color(value),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: project.colorValue == value
                              ? scheme.onSurface
                              : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                      child: project.colorValue == value
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteProject(
    BuildContext context,
    Project project,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目', style: TextStyle(fontSize: 15)),
        content: Text('确定删除「${project.name}」吗？里面的内容会一起删掉。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) store.deleteProject(project);
  }

  Future<void> _editProjectName(BuildContext context, Project? project) async {
    final controller = TextEditingController(text: project?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          project == null ? '新建项目' : '重命名项目',
          style: const TextStyle(fontSize: 15),
        ),
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

  static const _textColors = <(String?, Color)>[
    (null, Colors.transparent),
    ('#FF3B30', Color(0xFFFF3B30)),
    ('#FF9500', Color(0xFFFF9500)),
    ('#FFCC00', Color(0xFFFFCC00)),
    ('#34C759', Color(0xFF34C759)),
    ('#00C7BE', Color(0xFF00C7BE)),
    ('#0A84FF', Color(0xFF0A84FF)),
    ('#BF5AF2', Color(0xFFBF5AF2)),
    ('#FFFFFF', Color(0xFFFFFFFF)),
    ('#000000', Color(0xFF000000)),
  ];

  static const _fontSizes = <String?>[null, '13', '15', '18', '22'];

  /// Flutter's stock Windows selection menu uses 36px rows with asymmetric
  /// text padding. Keep Quill's real clipboard callbacks, but render them in
  /// a denser desktop menu that matches this compact app.
  Widget _buildEditorContextMenu(
    BuildContext context,
    QuillRawEditorState state,
  ) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return TextFieldTapRegion(
        child: AdaptiveTextSelectionToolbar.buttonItems(
          buttonItems: state.contextMenuButtonItems,
          anchors: state.contextMenuAnchors,
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final buttons = state.contextMenuButtonItems;
    if (buttons.isEmpty) return const SizedBox.shrink();
    return TextFieldTapRegion(
      child: DesktopTextSelectionToolbar(
        anchor: state.contextMenuAnchors.primaryAnchor,
        children: [
          for (final button in buttons)
            SizedBox(
              height: 32,
              width: double.infinity,
              child: TextButton(
                style: ButtonStyle(
                  alignment: Alignment.centerLeft,
                  minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 14),
                  ),
                  shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
                  foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
                  textStyle: const WidgetStatePropertyAll(
                    TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
                  ),
                ),
                onPressed: button.onPressed,
                child: Text(
                  AdaptiveTextSelectionToolbar.getButtonLabel(context, button),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditor(BuildContext context, Project project) {
    final base = Theme.of(context);
    final scheme = project.colorValue == 0
        ? base.colorScheme
        : base.colorScheme.copyWith(primary: Color(project.colorValue));
    // Quill derives its base text style from the ambient DefaultTextStyle,
    // so this keeps the document readable in both light and dark mode.
    return Stack(
      children: [
        DefaultTextStyle(
          key: ValueKey('editor-text-style-${project.id}'),
          // Segoe UI contains some CJK punctuation but not the surrounding
          // ideographs. Without a Chinese locale/font preference, Windows can
          // select different glyph families at Quill span boundaries, making
          // the same full-width comma or period jump from the baseline to the
          // vertical centre. Keep one CJK glyph family throughout the editor.
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: scheme.onSurface,
            locale: _editorLocale,
            fontFamily: defaultTargetPlatform == TargetPlatform.windows
                ? 'Microsoft YaHei UI'
                : null,
            fontFamilyFallback: _editorFontFallbacks,
          ),
          child: Listener(
            key: ValueKey('editor-pointer-listener-${project.id}'),
            behavior: HitTestBehavior.translucent,
            onPointerUp: (event) {
              _selectionAnchorFor(project).value = event.localPosition;
            },
            child: QuillEditor(
              key: ValueKey(project.id),
              controller: store.controllerFor(project),
              focusNode: _focusFor(project),
              scrollController: _scrollFor(project),
              config: QuillEditorConfig(
                placeholder: '随手记…',
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                expands: true,
                contextMenuBuilder: _buildEditorContextMenu,
                // Explicitly register the desktop paste accelerator. Quill also
                // inherits Flutter's editing shortcuts, but this local mapping
                // keeps Ctrl/Cmd+V working even when another Actions scope is
                // introduced around the panel.
                customShortcuts: {
                  SingleActivator(
                    LogicalKeyboardKey.keyV,
                    control: !_isMac,
                    meta: _isMac,
                  ): const PasteTextIntent(
                    SelectionChangedCause.keyboard,
                  ),
                },
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
        ),
        Positioned.fill(child: _buildSelectionPanel(context, project)),
      ],
    );
  }

  /// Editor widgets cached per project + theme inputs. A QuillEditor whose
  /// config identity changes re-lays out its whole document, so rebuilding
  /// one on every store notification (every keystroke, every tab switch)
  /// was the real source of the lag. Reusing the identical widget instance
  /// lets Flutter skip the update entirely.
  final _editorCache = <String, Widget>{};

  Widget _editorFor(BuildContext context, Project project) {
    final brightness = Theme.of(context).brightness;
    final key = '${project.id}|$brightness|${project.colorValue}';
    return _editorCache.putIfAbsent(key, () => _buildEditor(context, project));
  }

  /// Floating rich-text mini panel that appears while text is selected.
  Widget _buildSelectionPanel(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
    final controller = store.controllerFor(project);
    final anchor = _selectionAnchorFor(project);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final selection = controller.selection;
        final visible = selection.isValid && !selection.isCollapsed;
        final attrs = controller.getSelectionStyle().attributes;

        Widget iconBtn(
          IconData icon,
          String tooltip,
          VoidCallback onPressed, {
          bool active = false,
        }) {
          return IconButton(
            icon: Icon(icon, size: 17),
            tooltip: tooltip,
            style: const ButtonStyle(
              fixedSize: WidgetStatePropertyAll(Size.square(36)),
              minimumSize: WidgetStatePropertyAll(Size.square(36)),
              maximumSize: WidgetStatePropertyAll(Size.square(36)),
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            color: active ? scheme.primary : scheme.onSurfaceVariant,
            onPressed: onPressed,
          );
        }

        final sizeValue = attrs['size']?.value?.toString();
        final textColor = attrs['color']?.value?.toString();
        final background = attrs['background']?.value?.toString();
        final isTodo = attrs.containsKey(kTodoAttributeKey);

        final panel = Material(
          key: const ValueKey('selection-format-panel'),
          color: scheme.surfaceContainerHighest,
          elevation: 3,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                iconBtn(Icons.format_bold, '加粗', () {
                  controller.formatSelection(Attribute.bold);
                  _focusFor(project).requestFocus();
                }, active: attrs.containsKey('bold')),
                iconBtn(Icons.title, '标题', () {
                  final active = attrs['header'] != null;
                  controller.formatSelection(
                    Attribute.clone(Attribute.header, active ? null : 2),
                  );
                  _focusFor(project).requestFocus();
                }, active: attrs['header'] != null),
                Tooltip(
                  message: '字号',
                  child: AppMenuCombo<String?>(
                    key: const ValueKey('font-size-combo'),
                    width: 52,
                    height: 30,
                    value: sizeValue,
                    items: _fontSizes,
                    labelFor: (size) => size ?? '默认',
                    onChanged: (size) {
                      controller.formatSelection(
                        Attribute.clone(Attribute.size, size),
                      );
                      _focusFor(project).requestFocus();
                    },
                    textStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                    menuTextStyle: const TextStyle(fontSize: 12),
                    maxMenuWidth: 88,
                    itemHeight: 30,
                    buttonPadding: const EdgeInsets.only(left: 6, right: 2),
                    itemPadding: const EdgeInsets.only(left: 10, right: 12),
                    borderRadius: BorderRadius.circular(4),
                    backgroundColor: Colors.transparent,
                    foregroundColor: scheme.onSurfaceVariant,
                    iconSize: 15,
                  ),
                ),
                const SizedBox(width: 3),
                Tooltip(
                  message: '文字颜色',
                  child: AppMenuCombo<(String?, Color)>(
                    key: const ValueKey('text-color-combo'),
                    width: 44,
                    height: 30,
                    value: _textColors.firstWhere(
                      (option) => option.$1 == textColor,
                      orElse: () => _textColors.first,
                    ),
                    items: _textColors,
                    labelFor: (option) => _textColorLabel(option.$1),
                    onChanged: (option) {
                      controller.formatSelection(
                        Attribute.clone(Attribute.color, option.$1),
                      );
                      _focusFor(project).requestFocus();
                    },
                    minMenuWidth: 118,
                    maxMenuWidth: 148,
                    itemHeight: 30,
                    buttonPadding: const EdgeInsets.only(left: 6, right: 2),
                    itemPadding: const EdgeInsets.only(left: 10, right: 12),
                    borderRadius: BorderRadius.circular(4),
                    backgroundColor: Colors.transparent,
                    foregroundColor: scheme.onSurfaceVariant,
                    iconSize: 15,
                    showSelectedCheck: false,
                    buttonBuilder: (context, option, open) => Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _SelectionTextColorIndicator(
                          value: option.$1,
                          color: option.$2,
                        ),
                        const SizedBox(width: 2),
                        AppMenuComboArrow(
                          open: open,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    itemBuilder: (context, option, label, selected) =>
                        _SelectionColorOption(
                      value: option.$1,
                      color: option.$2,
                      label: label,
                      selected: selected,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Tooltip(
                  message: '背景色',
                  child: AppMenuCombo<(String?, Color)>(
                    key: const ValueKey('background-color-combo'),
                    width: 44,
                    height: 30,
                    value: _highlights.firstWhere(
                      (option) => option.$1 == background,
                      orElse: () => _highlights.first,
                    ),
                    items: _highlights,
                    labelFor: (option) => _highlightLabel(option.$1),
                    onChanged: (option) {
                      controller.formatSelection(
                        Attribute.clone(Attribute.background, option.$1),
                      );
                      _focusFor(project).requestFocus();
                    },
                    minMenuWidth: 118,
                    maxMenuWidth: 148,
                    itemHeight: 30,
                    buttonPadding: const EdgeInsets.only(left: 6, right: 2),
                    itemPadding: const EdgeInsets.only(left: 10, right: 12),
                    borderRadius: BorderRadius.circular(4),
                    backgroundColor: Colors.transparent,
                    foregroundColor: scheme.onSurfaceVariant,
                    iconSize: 15,
                    showSelectedCheck: false,
                    buttonBuilder: (context, option, open) => Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _SelectionColorSwatch(
                          value: option.$1,
                          color: option.$2,
                          selected: true,
                        ),
                        const SizedBox(width: 2),
                        AppMenuComboArrow(
                          open: open,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    itemBuilder: (context, option, label, selected) =>
                        _SelectionColorOption(
                      value: option.$1,
                      color: option.$2,
                      label: label,
                      selected: selected,
                    ),
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
                            _unmarkTodoSpanAnimated(project, start, length);
                          } else {
                            store.markTodoSpan(project, start, length);
                          }
                          _focusFor(project).requestFocus();
                        }
                      : () {},
                  active: isTodo,
                ),
              ],
            ),
          ),
        );

        return ValueListenableBuilder<Offset?>(
          valueListenable: anchor,
          builder: (context, anchorPosition, _) => IgnorePointer(
            ignoring: !visible,
            child: CustomSingleChildLayout(
              delegate: _SelectionPanelLayoutDelegate(anchor: anchorPosition),
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: panel,
              ),
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------- todo panel

  static String _highlightLabel(String? value) {
    return switch (value) {
      null => '无背景',
      'rgba(255,213,79,0.55)' => '黄色',
      'rgba(165,214,167,0.55)' => '绿色',
      'rgba(144,202,249,0.55)' => '蓝色',
      'rgba(244,143,177,0.55)' => '粉色',
      'rgba(255,171,145,0.55)' => '橙色',
      _ => '背景色',
    };
  }

  static String _textColorLabel(String? value) {
    return switch (value) {
      null => '默认文字',
      '#FF3B30' => '红色',
      '#FF9500' => '橙色',
      '#FFCC00' => '黄色',
      '#34C759' => '绿色',
      '#00C7BE' => '青色',
      '#0A84FF' => '蓝色',
      '#BF5AF2' => '紫色',
      '#FFFFFF' => '白色',
      '#000000' => '黑色',
      _ => '文字颜色',
    };
  }

  /// Todo spans of one project, grouped by their section (nearest heading).
  Map<String, List<TodoSpan>> _todoGroupsFor(Project project) {
    final sw = Stopwatch()..start();
    final ops = store.controllerFor(project).document.toDelta().toJson();
    final groups = <String, List<TodoSpan>>{};
    for (final span in parseTodoSpans(ops)) {
      groups.putIfAbsent(span.section, () => []).add(span);
    }
    if (sw.elapsedMilliseconds > 5) {
      debugPrint(
        '[perf] todo parse: ${sw.elapsedMilliseconds}ms '
        '(${ops.length} ops)',
      );
    }
    return groups;
  }

  List<_KeyedTodo> _keyedTodos(Project project, List<TodoSpan> todos) {
    final occurrences = <(String, String), int>{};
    return [
      for (final todo in todos)
        () {
          final signature = (todo.section, todo.text);
          final occurrence = occurrences[signature] ?? 0;
          occurrences[signature] = occurrence + 1;
          return (
            todo: todo,
            key: (
              projectId: project.id,
              section: todo.section,
              text: todo.text,
              occurrence: occurrence,
            ),
          );
        }(),
    ];
  }

  Future<void> _runTodoDismissal(
    Set<_TodoTileIdentity> keys,
    VoidCallback updateDocument,
  ) async {
    if (keys.isEmpty) {
      updateDocument();
      return;
    }
    setState(() => _dismissingTodos.addAll(keys));
    await Future<void>.delayed(_todoMotion);
    updateDocument();
    if (mounted) {
      setState(() => _dismissingTodos.removeAll(keys));
    }
  }

  Future<void> _unmarkTodoSpanAnimated(
    Project project,
    int start,
    int length,
  ) async {
    final end = start + length;
    final affected = <_TodoTileIdentity>{
      for (final group in _todoGroupsFor(project).values)
        for (final entry in _keyedTodos(project, group))
          if (entry.todo.start < end &&
              entry.todo.start + entry.todo.length > start)
            entry.key,
    };
    await _runTodoDismissal(
      affected,
      () => store.unmarkTodoSpan(project, start, length),
    );
    if (mounted) _focusFor(project).requestFocus();
  }

  Future<void> _clearCompleted(List<_TodoGroup> groups) async {
    if (_clearingDone) return;
    final completedKeys = <_TodoTileIdentity>{
      for (final group in groups)
        for (final entry in _keyedTodos(group.project, group.todos))
          if (entry.todo.done) entry.key,
    };
    if (completedKeys.isEmpty) return;

    setState(() => _clearingDone = true);
    await _runTodoDismissal(completedKeys, () {
      if (_todoShowAll) {
        for (final project in store.projects) {
          store.clearDone(project);
        }
      } else {
        final project = store.selected;
        if (project != null) store.clearDone(project);
      }
    });
    if (mounted) setState(() => _clearingDone = false);
  }

  void _toggleTodoExpanded(double maxHeight) {
    setState(() {
      if (_todoExpanded) {
        _todoPanelHeight = _todoHeightBeforeExpand
            .clamp(_todoHeaderHeight, maxHeight)
            .toDouble();
        _todoExpanded = false;
      } else {
        _todoHeightBeforeExpand =
            _todoPanelHeight.clamp(_todoHeaderHeight, maxHeight).toDouble();
        _todoPanelHeight = maxHeight;
        _todoExpanded = true;
      }
    });
  }

  void _startTodoResize(double maxHeight) {
    setState(() {
      if (_todoExpanded) {
        _todoPanelHeight = maxHeight;
      } else {
        _todoHeightBeforeExpand = _todoPanelHeight;
        _todoPanelHeight =
            _todoPanelHeight.clamp(_todoHeaderHeight, maxHeight).toDouble();
      }
      _todoExpanded = false;
      _resizingTodoPanel = true;
    });
  }

  void _updateTodoResize(double deltaY, double maxHeight) {
    setState(() {
      _todoPanelHeight = (_todoPanelHeight - deltaY)
          .clamp(_todoHeaderHeight, maxHeight)
          .toDouble();
    });
  }

  void _endTodoResize(double maxHeight) {
    setState(() {
      _resizingTodoPanel = false;
      _todoExpanded = _todoPanelHeight >= maxHeight - 0.5;
    });
  }

  Widget _buildTodoSection(BuildContext context, double maxHeight) {
    final scheme = Theme.of(context).colorScheme;
    final project = store.selected;

    // Groups of (header label, project, todos) depending on the scope.
    final groups = <_TodoGroup>[];
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
      0,
      (sum, g) => sum + g.todos.where((e) => !e.done).length,
    );
    final hasCompleted = groups.any((g) => g.todos.any((todo) => todo.done));

    final list = groups.isEmpty
        ? Center(
            child: Text(
              '在编辑板里划选一段文字，点浮动面板的 ☑ 列为待办',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
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
                      fontSize: _todoTextSize,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final entry in _keyedTodos(group.project, group.todos))
                  _buildTodoTile(context, group.project, entry.todo, entry.key),
              ],
            ],
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Column(
        children: [
          _buildTodoHeader(
            context,
            remaining,
            total,
            groups,
            hasCompleted,
            maxHeight,
          ),
          Expanded(child: list),
        ],
      ),
    );
  }

  Widget _buildTodoHeader(
    BuildContext context,
    int remaining,
    int total,
    List<_TodoGroup> groups,
    bool hasCompleted,
    double maxHeight,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _todoHeaderHovered = true),
      onExit: (_) => setState(() => _todoHeaderHovered = false),
      child: AnimatedContainer(
        key: const ValueKey('todo-header'),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        height: _todoHeaderHeight,
        color: _todoHeaderHovered
            ? scheme.primary.withValues(alpha: 0.055)
            : Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpDown,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: (_) => _startTodoResize(maxHeight),
                  onVerticalDragUpdate: (details) =>
                      _updateTodoResize(details.delta.dy, maxHeight),
                  onVerticalDragEnd: (_) => _endTodoResize(maxHeight),
                  onVerticalDragCancel: () => _endTodoResize(maxHeight),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Text(
                        '待办',
                        style: TextStyle(
                          fontSize: _todoTextSize,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedSwitcher(
                        duration: _todoMotion,
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: Text(
                          '剩余 $remaining / 共 $total',
                          key: ValueKey('$remaining:$total'),
                          style: TextStyle(
                            fontSize: _todoTextSize,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (store.projects.length > 1) ...[
                        const SizedBox(width: 10),
                        _buildScopeToggle(context),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '清除已完成待办',
              style: ButtonStyle(
                fixedSize: const WidgetStatePropertyAll(Size.square(40)),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                shape: const WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                ),
                animationDuration: const Duration(milliseconds: 140),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return scheme.onSurfaceVariant.withValues(alpha: 0.35);
                  }
                  if (_isDangerButtonActive(states)) return scheme.error;
                  return scheme.onSurfaceVariant;
                }),
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return Colors.transparent;
                  }
                  if (states.contains(WidgetState.pressed)) {
                    return scheme.error.withValues(alpha: 0.18);
                  }
                  if (_isDangerButtonActive(states)) {
                    return scheme.error.withValues(alpha: 0.12);
                  }
                  return Colors.transparent;
                }),
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              ),
              icon: AnimatedRotation(
                turns: _clearingDone ? 1 : 0,
                duration: _panelMotion,
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.done_all, size: 17),
              ),
              onPressed: hasCompleted && !_clearingDone
                  ? () => _clearCompleted(groups)
                  : null,
            ),
            IconButton(
              tooltip: _todoExpanded ? '收起待办区' : '待办区占满面板',
              style: const ButtonStyle(
                fixedSize: WidgetStatePropertyAll(Size.square(40)),
                padding: WidgetStatePropertyAll(EdgeInsets.zero),
              ),
              icon: AnimatedSwitcher(
                duration: _todoMotion,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  _todoExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
                  key: ValueKey(_todoExpanded),
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              onPressed: () => _toggleTodoExpanded(maxHeight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScopeToggle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String label, bool active, VoidCallback onTap) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: _todoMotion,
          curve: Curves.easeOut,
          height: 28,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: active ? Colors.white : scheme.onSurfaceVariant,
            ),
          ),
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
          pill(
            '本项目',
            !_todoShowAll,
            () => setState(() => _todoShowAll = false),
          ),
          pill('全部', _todoShowAll, () => setState(() => _todoShowAll = true)),
        ],
      ),
    );
  }

  Widget _buildTodoTile(
    BuildContext context,
    Project project,
    TodoSpan todo,
    _TodoTileIdentity animationKey,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // In the all-projects view each todo's checkbox follows its own
    // project's theme color; the default blue applies when unset.
    final accent =
        project.colorValue == 0 ? scheme.primary : Color(project.colorValue);
    final dismissing = _dismissingTodos.contains(animationKey);
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => store.toggleSpanDone(project, todo),
            child: AnimatedSwitcher(
              duration: _todoMotion,
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                todo.done ? Icons.check_circle : Icons.radio_button_unchecked,
                key: ValueKey(todo.done),
                size: 17,
                color: todo.done ? scheme.onSurfaceVariant : accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => _revealSpan(project, todo),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: _todoMotion,
                  curve: Curves.easeOut,
                  style: TextStyle(
                    fontSize: _todoTextSize,
                    decoration: todo.done ? TextDecoration.lineThrough : null,
                    color:
                        todo.done ? scheme.onSurfaceVariant : scheme.onSurface,
                  ),
                  child: Text(todo.text),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return TweenAnimationBuilder<double>(
      key: ValueKey(animationKey),
      tween: Tween<double>(begin: 0, end: 1),
      duration: _todoMotion,
      curve: Curves.easeOut,
      child: AnimatedAlign(
        alignment: Alignment.topCenter,
        heightFactor: dismissing ? 0 : 1,
        duration: _todoMotion,
        curve: Curves.easeInOut,
        child: AnimatedOpacity(
          opacity: dismissing ? 0 : 1,
          duration: _todoMotion,
          child: tile,
        ),
      ),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 4 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}

class _SelectionPanelLayoutDelegate extends SingleChildLayoutDelegate {
  const _SelectionPanelLayoutDelegate({required this.anchor});

  static const double _margin = 8;
  static const double _gap = 10;

  final Offset? anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: (constraints.maxWidth - _margin * 2)
          .clamp(0, double.infinity)
          .toDouble(),
      maxHeight: (constraints.maxHeight - _margin * 2)
          .clamp(0, double.infinity)
          .toDouble(),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final target = anchor;
    if (target == null) {
      return Offset(
        ((size.width - childSize.width) / 2)
            .clamp(
              _margin,
              (size.width - childSize.width - _margin).clamp(
                _margin,
                double.infinity,
              ),
            )
            .toDouble(),
        (size.height - childSize.height - _margin)
            .clamp(_margin, double.infinity)
            .toDouble(),
      );
    }

    final maxLeft = (size.width - childSize.width - _margin).clamp(
      _margin,
      double.infinity,
    );
    final left =
        (target.dx - childSize.width / 2).clamp(_margin, maxLeft).toDouble();
    var top = target.dy + _gap;
    if (top + childSize.height > size.height - _margin) {
      top = target.dy - childSize.height - _gap;
    }
    final maxTop = (size.height - childSize.height - _margin).clamp(
      _margin,
      double.infinity,
    );
    return Offset(left, top.clamp(_margin, maxTop).toDouble());
  }

  @override
  bool shouldRelayout(_SelectionPanelLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor;
}

class _SelectionColorOption extends StatelessWidget {
  const _SelectionColorOption({
    required this.value,
    required this.color,
    required this.label,
    required this.selected,
  });

  final String? value;
  final Color color;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: selected
              ? Icon(Icons.check, size: 16, color: scheme.primary)
              : null,
        ),
        _SelectionColorSwatch(value: value, color: color, selected: selected),
        const SizedBox(width: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: selected ? scheme.primary : scheme.onSurface,
              ),
        ),
      ],
    );
  }
}

class _SelectionTextColorIndicator extends StatelessWidget {
  const _SelectionTextColorIndicator({
    required this.value,
    required this.color,
  });

  final String? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor = value == null ? scheme.onSurfaceVariant : color;
    return SizedBox(
      width: 15,
      height: 20,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'A',
            style: TextStyle(
              height: 1,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: effectiveColor,
              shadows: color.computeLuminance() > 0.9
                  ? [Shadow(color: scheme.outline, blurRadius: 1)]
                  : null,
            ),
          ),
          const SizedBox(height: 1),
          Container(width: 13, height: 2, color: effectiveColor),
        ],
      ),
    );
  }
}

class _SelectionColorSwatch extends StatelessWidget {
  const _SelectionColorSwatch({
    required this.value,
    required this.color,
    required this.selected,
  });

  final String? value;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final swatchColor = value == null ? scheme.surface : color;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: swatchColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: SizedBox(
        width: 14,
        height: 14,
        child: value == null
            ? Icon(Icons.block, size: 9, color: scheme.onSurfaceVariant)
            : null,
      ),
    );
  }
}

/// A Chrome-style tab with immediate press feedback, hover state and a
/// short background animation.
class _ProjectTab extends StatefulWidget {
  const _ProjectTab({
    required this.selected,
    required this.projectColor,
    required this.name,
    required this.textColor,
    required this.surfaceColor,
    required this.onPressed,
    required this.onLongPress,
  });

  final bool selected;
  final Color? projectColor;
  final String name;
  final Color textColor;
  final Color surfaceColor;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  State<_ProjectTab> createState() => _ProjectTabState();
}

class _ProjectTabState extends State<_ProjectTab> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color background;
    if (widget.selected) {
      // The selected tab uses the content background color, so it reads as
      // one surface with the editor below (Chrome-style).
      background = widget.surfaceColor;
    } else if (_pressed) {
      background = widget.surfaceColor.withValues(alpha: 0.85);
    } else if (_hovered) {
      background = widget.surfaceColor.withValues(alpha: 0.45);
    } else {
      background = Colors.transparent;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // Act on the raw pointer event: DragToMoveArea registers a double-tap
      // recognizer (double-click to maximize), which holds the gesture arena
      // for the ~300ms double-tap timeout before TapGestureRecognizer
      // callbacks fire. Listener bypasses the arena entirely.
      child: Listener(
        onPointerDown: (_) {
          setState(() => _pressed = true);
          widget.onPressed();
        },
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: GestureDetector(
          onLongPress: widget.onLongPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(maxWidth: 140),
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.projectColor != null) ...[
                  Icon(Icons.circle, size: 7, color: widget.projectColor),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: Text(
                    widget.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: widget.textColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
