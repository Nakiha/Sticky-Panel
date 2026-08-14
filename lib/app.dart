import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'store.dart';
import 'todos.dart';
import 'widgets/app_menu_combo.dart';

const _defaultProjectBlue = Color(0xFF007AFF);
const _defaultProjectBlueDark = Color(0xFF0A84FF);
const kAppDisplayName = '随手记';

Color _defaultProjectAccent(Brightness brightness) {
  return brightness == Brightness.dark
      ? _defaultProjectBlueDark
      : _defaultProjectBlue;
}

Color _projectAccent(Project project, Brightness brightness) =>
    project.colorValue == 0
    ? _defaultProjectAccent(brightness)
    : Color(project.colorValue);

typedef _TodoGroup = ({String label, Project project, List<TodoSpan> todos});
typedef _TodoTileIdentity = ({
  String projectId,
  String section,
  String text,
  int occurrence,
});
typedef _KeyedTodo = ({TodoSpan todo, _TodoTileIdentity key});
typedef _SelectionPanelPreference = ({
  TextSelection selection,
  double pointerX,
});
typedef _SelectionPanelAnchor = ({Rect selectionRect, double preferredX});

class _ToggleTodoIntent extends Intent {
  const _ToggleTodoIntent();
}

enum _CloseChoice { hideToTray, exitApplication }

class StickyPanelApp extends StatelessWidget {
  const StickyPanelApp({
    super.key,
    required this.store,
    this.enableSystemTray = false,
  });

  final AppStore store;
  final bool enableSystemTray;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppDisplayName,
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
          primary: _defaultProjectBlue,
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
          primary: _defaultProjectBlueDark,
          surface: Color(0xFF1C1C1E),
          onSurface: Color(0xFFF2F2F7),
          onSurfaceVariant: Color(0xFF8E8E93),
          outlineVariant: Color(0xFF38383A),
          surfaceContainerHighest: Color(0xFF2C2C2E),
        ),
      ),
      home: HomePage(store: store, enableSystemTray: enableSystemTray),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.store,
    required this.enableSystemTray,
  });

  final AppStore store;
  final bool enableSystemTray;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener, TrayListener {
  static const _trayIconAsset = 'windows/runner/resources/tray_icon.ico';
  static const _trayShowKey = 'show_window';
  static const _trayResetCloseKey = 'reset_close_preference';
  static const _trayExitKey = 'exit_app';
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
  bool _trayReady = false;
  bool _exitRequested = false;
  bool _clearingDone = false;
  double _todoPanelHeight = _defaultTodoPanelHeight;
  double _todoHeightBeforeExpand = _defaultTodoPanelHeight;
  final Set<_TodoTileIdentity> _dismissingTodos = {};

  /// One focus node / scroll controller per project: all editors stay alive
  /// in an IndexedStack, so sharing a single ScrollController would attach
  /// it to multiple scroll views and throw on every tab switch.
  final _editorFocusNodes = <String, FocusNode>{};
  final _editorScrollControllers = <String, ScrollController>{};
  final _editorKeys = <String, GlobalKey<EditorState>>{};
  final _editorStackKeys = <String, GlobalKey>{};

  /// A completed mouse selection may supply a preferred horizontal position.
  /// Vertical placement always comes from the actual selection geometry.
  final _selectionPanelPreferences =
      <String, ValueNotifier<_SelectionPanelPreference?>>{};

  /// True while the pointer is down in the editor: the panel stays hidden
  /// during the drag so it can't fly around, and appears on release.
  /// A ValueNotifier so the (cached) editor widget subtree rebuilds even
  /// though HomePage-level setState cannot reach into the cache.
  final _selectingNotifier = ValueNotifier<bool>(false);

  /// Closes root-overlay menus before the todo panel starts changing layout.
  /// Waiting for the selection toolbar's next rebuild is one frame too late.
  final _selectionPanelDismissals = ValueNotifier<int>(0);

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_pruneEditorAttachments);
    windowManager.addListener(this);
    if (widget.enableSystemTray) {
      trayManager.addListener(this);
      unawaited(_initSystemTray());
    }
  }

  FocusNode _focusFor(Project project) =>
      _editorFocusNodes.putIfAbsent(project.id, FocusNode.new);

  ScrollController _scrollFor(Project project) =>
      _editorScrollControllers.putIfAbsent(project.id, ScrollController.new);

  GlobalKey<EditorState> _editorKeyFor(Project project) =>
      _editorKeys.putIfAbsent(project.id, GlobalKey<EditorState>.new);

  GlobalKey _editorStackKeyFor(Project project) =>
      _editorStackKeys.putIfAbsent(project.id, GlobalKey.new);

  ValueNotifier<_SelectionPanelPreference?> _selectionPreferenceFor(
    Project project,
  ) => _selectionPanelPreferences.putIfAbsent(
    project.id,
    () => ValueNotifier<_SelectionPanelPreference?>(null),
  );

  void _pruneEditorAttachments() {
    final live = store.projects.map((p) => p.id).toSet();
    for (final id
        in _editorFocusNodes.keys.where((id) => !live.contains(id)).toList()) {
      _editorFocusNodes.remove(id)?.dispose();
    }
    for (final id
        in _editorScrollControllers.keys
            .where((id) => !live.contains(id))
            .toList()) {
      _editorScrollControllers.remove(id)?.dispose();
    }
    for (final id
        in _selectionPanelPreferences.keys
            .where((id) => !live.contains(id))
            .toList()) {
      _selectionPanelPreferences.remove(id)?.dispose();
    }
    _editorKeys.removeWhere((id, _) => !live.contains(id));
    _editorStackKeys.removeWhere((id, _) => !live.contains(id));
    _editorCache.removeWhere((key, _) => !live.contains(key.split('|').first));
  }

  @override
  void dispose() {
    store.removeListener(_pruneEditorAttachments);
    windowManager.removeListener(this);
    if (widget.enableSystemTray) {
      trayManager.removeListener(this);
    }
    for (final node in _editorFocusNodes.values) {
      node.dispose();
    }
    for (final controller in _editorScrollControllers.values) {
      controller.dispose();
    }
    for (final preference in _selectionPanelPreferences.values) {
      preference.dispose();
    }
    _selectingNotifier.dispose();
    _selectionPanelDismissals.dispose();
    super.dispose();
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    setState(() {});
  }

  Future<void> _initSystemTray() async {
    try {
      await trayManager.setIcon(_trayIconAsset);
      await trayManager.setToolTip(kAppDisplayName);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: _trayShowKey, label: '显示$kAppDisplayName'),
            MenuItem.separator(),
            MenuItem(key: _trayResetCloseKey, label: '恢复关闭时询问'),
            MenuItem.separator(),
            MenuItem(key: _trayExitKey, label: '彻底退出'),
          ],
        ),
      );
      _trayReady = true;
    } catch (error, stackTrace) {
      debugPrint('Failed to initialize system tray: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _showWindowFromTray() async {
    await windowManager.show();
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
  }

  Future<void> _exitApplication({ClosePreference? rememberPreference}) async {
    if (_exitRequested) return;
    _exitRequested = true;
    // Remove the window immediately so the user never watches a frozen final
    // frame while preferences and plugins finish their shutdown work.
    try {
      await windowManager.hide();
    } catch (error) {
      debugPrint('Failed to hide window before exit: $error');
    }
    if (rememberPreference != null) {
      try {
        await store.setClosePreference(rememberPreference);
      } catch (error) {
        debugPrint('Failed to persist close preference: $error');
      }
    }
    // Flush the latest editor state before tearing down the engine. The
    // regular edit listener persists asynchronously, so an immediate native
    // quit must not race the final SharedPreferences write.
    try {
      await store.persist();
    } catch (error) {
      // A persistence failure must not leave an invisible process behind.
      debugPrint('Failed to persist state before exit: $error');
    }
    if (_trayReady) {
      try {
        await trayManager.destroy();
        _trayReady = false;
      } catch (error) {
        debugPrint('Failed to destroy system tray: $error');
      }
    }
    // Release interception, then close the native window normally. On Windows
    // this posts SC_CLOSE, destroys the HWND immediately, and lets the runner's
    // SetQuitOnClose path stop the message loop after the window is gone.
    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      debugPrint('Failed to release close interception: $error');
    }
    try {
      await windowManager.close();
    } catch (error) {
      // destroy() remains a last-resort process-loop fallback.
      debugPrint('Failed to close native window: $error');
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindowFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _trayShowKey:
        unawaited(_showWindowFromTray());
        return;
      case _trayResetCloseKey:
        unawaited(store.setClosePreference(ClosePreference.ask));
        return;
      case _trayExitKey:
        unawaited(_exitApplication());
        return;
    }
  }

  @override
  void onWindowClose() {
    _requestClose();
  }

  Future<void> _requestClose() async {
    if (_exitRequested || _closeDialogOpen || !mounted) return;
    _closeDialogOpen = true;
    try {
      final canUseTray = widget.enableSystemTray && _trayReady;
      if (canUseTray) {
        switch (store.closePreference) {
          case ClosePreference.hideToTray:
            await windowManager.hide();
            return;
          case ClosePreference.exitApplication:
            await _exitApplication();
            return;
          case ClosePreference.ask:
            break;
        }
        if (!mounted) return;

        var rememberChoice = false;
        final choice = await showDialog<_CloseChoice>(
          context: context,
          barrierDismissible: false,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text(
                '关闭$kAppDisplayName',
                style: TextStyle(fontSize: 15),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('关闭窗口时要怎么处理？'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: rememberChoice,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      '记住选择，下次不再提示',
                      style: TextStyle(fontSize: 13),
                    ),
                    onChanged: (value) {
                      setDialogState(() => rememberChoice = value ?? false);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, _CloseChoice.hideToTray),
                  child: const Text('隐藏到系统托盘'),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, _CloseChoice.exitApplication),
                  child: const Text(
                    '退出应用',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
        );
        if (choice == null) return;

        if (choice == _CloseChoice.hideToTray) {
          await windowManager.hide();
          if (rememberChoice) {
            await store.setClosePreference(ClosePreference.hideToTray);
          }
        } else {
          await _exitApplication(
            rememberPreference: rememberChoice
                ? ClosePreference.exitApplication
                : null,
          );
        }
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text(
            '关闭$kAppDisplayName',
            style: TextStyle(fontSize: 15),
          ),
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
      await _exitApplication();
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
        final scheme = project == null
            ? base.colorScheme
            : base.colorScheme.copyWith(
                primary: _projectAccent(project, base.brightness),
              );
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
    final todoHeight = requestedHeight
        .clamp(_todoHeaderHeight, maxTodoHeight)
        .toDouble();

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

  /// Edge-style title bar: pin first, then the project tabs and a trailing
  /// add button that stays attached to the last tab. Only the native window
  /// controls consume the full title-bar height.
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
            if (_isMac) const SizedBox(width: 72),
            _tabStripIcon(
              _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
              _alwaysOnTop ? '取消置顶' : '窗口置顶',
              _toggleAlwaysOnTop,
              active: _alwaysOnTop,
              neutralActive: true,
              padding: const EdgeInsets.all(4),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('project-tab-strip'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (
                      var index = 0;
                      index < store.projects.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 2),
                      _buildTab(context, store.projects[index], index),
                    ],
                    if (store.projects.isNotEmpty) const SizedBox(width: 2),
                    _tabStripIcon(
                      Icons.add,
                      '新建项目',
                      () => _editProjectName(context, null),
                    ),
                  ],
                ),
              ),
            ),
            if (!_isMac) ...[
              _titleBarIcon(Icons.minimize, '最小化', windowManager.minimize),
              _titleBarIcon(Icons.close, '关闭', _requestClose, danger: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tabStripIcon(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    bool active = false,
    bool neutralActive = false,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(vertical: 4),
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 17),
        style: _panelIconButtonStyle(
          scheme,
          size: const Size(32, 28),
          active: active,
          neutralActive: neutralActive,
          borderRadius: 7,
        ),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildTab(BuildContext context, Project project, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = index == store.selectedIndex;
    final projectColor = _projectAccent(project, Theme.of(context).brightness);
    return _ProjectTab(
      key: ValueKey('project-tab-${project.id}'),
      selected: selected,
      projectId: project.id,
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
      style: _panelIconButtonStyle(
        scheme,
        size: const Size(40, 36),
        active: active,
        danger: danger,
      ),
      onPressed: onPressed,
    );
  }

  ButtonStyle _panelIconButtonStyle(
    ColorScheme scheme, {
    required Size size,
    bool active = false,
    bool neutralActive = false,
    bool danger = false,
    double borderRadius = 4,
  }) {
    return ButtonStyle(
      fixedSize: WidgetStatePropertyAll(size),
      minimumSize: WidgetStatePropertyAll(size),
      maximumSize: WidgetStatePropertyAll(size),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(borderRadius)),
        ),
      ),
      animationDuration: const Duration(milliseconds: 140),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurfaceVariant.withValues(alpha: 0.35);
        }
        if (danger && _isInteractiveButtonState(states)) return scheme.error;
        if (!active) return scheme.onSurfaceVariant;
        return neutralActive ? scheme.onSurface : scheme.primary;
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (danger) {
          if (states.contains(WidgetState.pressed)) {
            return scheme.error.withValues(alpha: 0.18);
          }
          if (_isInteractiveButtonState(states)) {
            return scheme.error.withValues(alpha: 0.12);
          }
          return Colors.transparent;
        }
        if (states.contains(WidgetState.pressed)) {
          return scheme.onSurface.withValues(alpha: 0.12);
        }
        if (_isInteractiveButtonState(states)) {
          return scheme.onSurface.withValues(alpha: 0.07);
        }
        return Colors.transparent;
      }),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    );
  }

  bool _isInteractiveButtonState(Set<WidgetState> states) =>
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
    final defaultBlue = _defaultProjectAccent(Theme.of(context).brightness);
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
                      key: ValueKey('project-color-$value'),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: value == 0 ? defaultBlue : Color(value),
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

  static const _fontSizes = <String>['13', '14', '15', '18', '22'];

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
    final controller = store.controllerFor(project);
    final scheme = base.colorScheme.copyWith(
      primary: _projectAccent(project, base.brightness),
    );
    // Quill derives its base text style from the ambient DefaultTextStyle,
    // so this keeps the document readable in both light and dark mode.
    return Stack(
      key: _editorStackKeyFor(project),
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
            // Track drag selection: the panel hides while the pointer is
            // down and reappears next to the cursor on release.
            onPointerDown: (_) => _selectingNotifier.value = true,
            onPointerUp: (event) {
              final selection = controller.selection;
              if (selection.isValid && !selection.isCollapsed) {
                _selectionPreferenceFor(project).value = (
                  selection: selection,
                  pointerX: event.localPosition.dx,
                );
              }
              _selectingNotifier.value = false;
            },
            onPointerCancel: (_) => _selectingNotifier.value = false,
            child: QuillEditor(
              key: ValueKey(project.id),
              controller: controller,
              focusNode: _focusFor(project),
              scrollController: _scrollFor(project),
              config: QuillEditorConfig(
                editorKey: _editorKeyFor(project),
                // Keep the insertion caret neutral like the document text.
                // Project accents still identify selections and todo marks,
                // without turning the writing cursor into another theme mark.
                textSelectionThemeData: TextSelectionThemeData(
                  cursorColor: scheme.onSurface,
                  selectionColor: scheme.primary.withValues(alpha: 0.32),
                  selectionHandleColor: scheme.primary,
                ),
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
                  SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: !_isMac,
                    meta: _isMac,
                  ): const _ToggleTodoIntent(),
                },
                customActions: {
                  _ToggleTodoIntent: CallbackAction<_ToggleTodoIntent>(
                    onInvoke: (_) {
                      _toggleTodoForSelection(project);
                      return null;
                    },
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
                    // Completed text uses the same quiet grey strike as the
                    // todo list. Keep the open marker accented, but make it
                    // thinner so its upper edge no longer cuts into the
                    // bottom strokes of Chinese glyphs on Windows.
                    decorationColor: done
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                    decorationThickness: done ? 1 : 0.6,
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

  _SelectionPanelAnchor? _selectionPanelAnchorFor(
    Project project,
    TextSelection selection, {
    double? pointerX,
  }) {
    if (!selection.isValid || selection.isCollapsed) return null;

    final editorState = _editorKeyFor(project).currentState;
    final stackBox =
        _editorStackKeyFor(project).currentContext?.findRenderObject()
            as RenderBox?;
    if (editorState == null ||
        stackBox == null ||
        !stackBox.hasSize ||
        !editorState.renderEditor.hasSize) {
      return null;
    }

    final editor = editorState.renderEditor;
    final startRect = editor.getLocalRectForCaret(
      TextPosition(offset: selection.start),
    );
    final endRect = editor.getLocalRectForCaret(
      TextPosition(offset: selection.end, affinity: TextAffinity.upstream),
    );
    final endpoints = editor.getEndpointsForSelection(selection);
    final endpointBottom = endpoints.fold<double>(
      0,
      (bottom, endpoint) => math.max(bottom, endpoint.point.dy),
    );
    final sameLine = (startRect.center.dy - endRect.center.dy).abs() < 1;
    final localRect = Rect.fromLTRB(
      sameLine ? math.min(startRect.left, endRect.left) : 0,
      math.min(startRect.top, endRect.top),
      sameLine ? math.max(startRect.right, endRect.right) : editor.size.width,
      math.max(math.max(startRect.bottom, endRect.bottom), endpointBottom),
    );
    final topLeft = editor.localToGlobal(localRect.topLeft, ancestor: stackBox);
    final bottomRight = editor.localToGlobal(
      localRect.bottomRight,
      ancestor: stackBox,
    );
    final selectionRect = Rect.fromPoints(topLeft, bottomRight);
    return (
      selectionRect: selectionRect,
      preferredX: pointerX ?? selectionRect.center.dx,
    );
  }

  /// Floating rich-text mini panel that appears while text is selected.
  Widget _buildSelectionPanel(BuildContext context, Project project) {
    final scheme = Theme.of(context).colorScheme;
    final controller = store.controllerFor(project);
    final preference = _selectionPreferenceFor(project);
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        _selectingNotifier,
        preference,
        _scrollFor(project),
      ]),
      builder: (context, _) {
        final selection = controller.selection;
        final visible =
            selection.isValid &&
            !selection.isCollapsed &&
            !_selectingNotifier.value;
        final attrs = controller.getSelectionStyle().attributes;

        Widget iconBtn(
          IconData icon,
          String tooltip,
          VoidCallback onPressed, {
          bool active = false,
        }) {
          return IconButton(
            icon: Icon(icon, size: 16),
            tooltip: tooltip,
            style: _panelIconButtonStyle(
              scheme,
              size: const Size.square(32),
              active: active,
            ),
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
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 3),
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
                  child: AppMenuCombo<String>(
                    key: const ValueKey('font-size-combo'),
                    width: 40,
                    height: 26,
                    // No explicit size attribute means the 14px base style.
                    value: sizeValue ?? '14',
                    items: _fontSizes,
                    labelFor: (size) => size,
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
                    enabled: visible,
                    closeListenable: _selectionPanelDismissals,
                  ),
                ),
                const SizedBox(width: 3),
                Tooltip(
                  message: '文字颜色',
                  child: AppMenuCombo<(String?, Color)>(
                    key: const ValueKey('text-color-combo'),
                    width: 44,
                    height: 26,
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
                    enabled: visible,
                    closeListenable: _selectionPanelDismissals,
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
                    height: 26,
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
                    enabled: visible,
                    closeListenable: _selectionPanelDismissals,
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
                  '${isTodo ? '取消待办' : '列为待办'} '
                  '(${_isMac ? '⌘' : 'Ctrl'}+Enter)',
                  visible
                      ? () => _toggleTodoForSelection(project)
                      : () {},
                  active: isTodo,
                ),
              ],
            ),
          ),
        );

        final pointerPreference = preference.value;
        final anchor = _selectionPanelAnchorFor(
          project,
          selection,
          pointerX: pointerPreference?.selection == selection
              ? pointerPreference?.pointerX
              : null,
        );

        // The selection rect determines vertical avoidance. Mouse release only
        // influences the horizontal position, so the panel can never blindly
        // cover the text where the drag happened.
        return IgnorePointer(
          ignoring: !visible,
          child: CustomSingleChildLayout(
            delegate: _SelectionPanelLayoutDelegate(anchor: anchor),
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              // Hiding must be immediate. Otherwise the todo panel can grow
              // underneath a still-fading toolbar (and any root-overlay menu)
              // for one or two frames.
              duration: visible
                  ? const Duration(milliseconds: 120)
                  : Duration.zero,
              child: panel,
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

  void _toggleTodoForSelection(Project project) {
    final controller = store.controllerFor(project);
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;

    final start = selection.start;
    final length = selection.end - selection.start;
    final isTodo = controller
        .getSelectionStyle()
        .attributes
        .containsKey(kTodoAttributeKey);
    if (isTodo) {
      unawaited(_unmarkTodoSpanAnimated(project, start, length));
    } else {
      store.markTodoSpan(project, start, length);
      _focusFor(project).requestFocus();
    }
  }

  void _dismissSelectionPanel() {
    final project = store.selected;
    if (project == null) return;
    final controller = store.controllerFor(project);
    final selection = controller.selection;
    _selectionPanelDismissals.value++;
    _selectionPreferenceFor(project).value = null;
    _selectingNotifier.value = false;
    if (selection.isValid && !selection.isCollapsed) {
      controller.updateSelection(
        TextSelection.collapsed(offset: selection.extentOffset),
        ChangeSource.local,
      );
    }
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
    if (!_todoExpanded) _dismissSelectionPanel();
    setState(() {
      if (_todoExpanded) {
        _todoPanelHeight = _todoHeightBeforeExpand
            .clamp(_todoHeaderHeight, maxHeight)
            .toDouble();
        _todoExpanded = false;
      } else {
        _todoHeightBeforeExpand = _todoPanelHeight
            .clamp(_todoHeaderHeight, maxHeight)
            .toDouble();
        _todoPanelHeight = maxHeight;
        _todoExpanded = true;
      }
    });
  }

  void _startTodoResize(double maxHeight) {
    _dismissSelectionPanel();
    setState(() {
      if (_todoExpanded) {
        _todoPanelHeight = maxHeight;
      } else {
        _todoHeightBeforeExpand = _todoPanelHeight;
        _todoPanelHeight = _todoPanelHeight
            .clamp(_todoHeaderHeight, maxHeight)
            .toDouble();
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
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            children: [
              for (final group in groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 2),
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
            ? scheme.onSurface.withValues(alpha: 0.06)
            : Colors.transparent,
        child: Row(
          children: [
            Expanded(
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
                    // Plain text, no AnimatedSwitcher: its default layout
                    // centers the old/new children while cross-fading, so a
                    // width change made the count visibly wobble.
                    Text(
                      '剩余 $remaining / 共 $total',
                      style: TextStyle(
                        fontSize: _todoTextSize,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Pinned to the right so it doesn't shift when the count
            // text changes width.
            if (store.projects.length > 1) _buildScopeToggle(context),
            IconButton(
              tooltip: '清除已完成待办',
              style: _panelIconButtonStyle(
                scheme,
                size: const Size.square(40),
                danger: true,
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
              style: _panelIconButtonStyle(scheme, size: const Size.square(40)),
              icon: AnimatedSwitcher(
                duration: _todoMotion,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  _todoExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
                  key: ValueKey(_todoExpanded),
                  size: 18,
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
    final accent = _projectAccent(project, Theme.of(context).brightness);
    final dismissing = _dismissingTodos.contains(animationKey);
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Match the first text line instead of centring against the full
            // height of a wrapped todo, so every checkbox stays predictable.
            padding: const EdgeInsets.only(top: 3),
            child: GestureDetector(
              onTap: () => store.toggleSpanDone(project, todo),
              child: AnimatedSwitcher(
                duration: _todoMotion,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  todo.done
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  key: ValueKey('todo-indicator-${project.id}-${todo.start}'),
                  size: 17,
                  color: todo.done ? scheme.onSurfaceVariant : accent,
                ),
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
                    color: todo.done
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
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

/// Positions the selection panel outside the selected text. The selection
/// geometry owns vertical placement; a mouse release only biases horizontal
/// placement.
class _SelectionPanelLayoutDelegate extends SingleChildLayoutDelegate {
  const _SelectionPanelLayoutDelegate({required this.anchor});

  static const double _margin = 8;
  static const double _selectionGap = 10;

  final _SelectionPanelAnchor? anchor;

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
    final maxLeft = (size.width - childSize.width - _margin).clamp(
      _margin,
      double.infinity,
    );
    final maxTop = (size.height - childSize.height - _margin).clamp(
      _margin,
      double.infinity,
    );

    final target = anchor;
    if (target == null) {
      // Geometry can be temporarily unavailable during the first layout.
      return Offset(12, maxTop.toDouble());
    }

    final left = (target.preferredX - childSize.width / 2)
        .clamp(_margin, maxLeft)
        .toDouble();
    final exclusion = target.selectionRect.inflate(_selectionGap);
    final aboveTop = exclusion.top - childSize.height;
    final belowTop = exclusion.bottom;
    final aboveFits = aboveTop >= _margin;
    final belowFits = belowTop <= maxTop;

    // Above is the least disruptive default: it leaves the selected text and
    // the following line visible for the user's next edit. Flip below only
    // when the upper candidate cannot fit.
    final double top;
    if (aboveFits) {
      top = aboveTop;
    } else if (belowFits) {
      top = belowTop;
    } else {
      final roomAbove = exclusion.top - _margin;
      final roomBelow = size.height - _margin - exclusion.bottom;
      top = roomAbove >= roomBelow ? _margin : maxTop.toDouble();
    }
    return Offset(left, top);
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
    super.key,
    required this.selected,
    required this.projectId,
    required this.projectColor,
    required this.name,
    required this.textColor,
    required this.surfaceColor,
    required this.onPressed,
    required this.onLongPress,
  });

  final bool selected;
  final String projectId;
  final Color projectColor;
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
                Icon(
                  Icons.circle,
                  key: ValueKey('project-color-dot-${widget.projectId}'),
                  size: 7,
                  color: widget.projectColor,
                ),
                const SizedBox(width: 5),
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
