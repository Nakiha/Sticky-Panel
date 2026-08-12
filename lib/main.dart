import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Divider, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'model/panel_state.dart';
import 'services/panel_store.dart';

const _blue = Color(0xFF0A84FF);
const _ink = Color(0xFF202124);
const _secondaryInk = Color(0xFF777773);
const _hairline = Color(0x1F4A4A45);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await acrylic.Window.initialize();
  await windowManager.ensureInitialized();

  final store = PanelStore();
  final state = await store.load();
  final initialSize = Size(
    state.width.clamp(320, 900).toDouble(),
    state.height.clamp(360, 1200).toDouble(),
  );

  final options = WindowOptions(
    size: initialSize,
    minimumSize: const Size(320, 360),
    center: state.x == null || state.y == null,
    backgroundColor: const Color(0x00000000),
    skipTaskbar: false,
    title: 'Sticky Panel',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    if (state.x != null && state.y != null) {
      await windowManager.setPosition(Offset(state.x!, state.y!));
    }
    await windowManager.setAlwaysOnTop(state.alwaysOnTop);
    await acrylic.Window.setEffect(
      effect: acrylic.WindowEffect.acrylic,
      color: const Color(0xDDF5F2EA),
      dark: false,
    );
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(StickPanelApp(store: store, state: state));
}

class StickPanelApp extends StatelessWidget {
  const StickPanelApp({
    required this.store,
    required this.state,
    super.key,
  });

  final PanelStore store;
  final PanelState state;

  @override
  Widget build(BuildContext context) {
    const baseText = TextStyle(
      fontFamily: 'Segoe UI Variable',
      fontFamilyFallback: ['Segoe UI', 'Segoe UI Emoji'],
      color: _ink,
      fontSize: 14,
    );

    return CupertinoApp(
      title: 'Sticky Panel',
      debugShowCheckedModeBanner: false,
      theme: const CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: _blue,
        scaffoldBackgroundColor: Color(0x00000000),
        barBackgroundColor: Color(0x00000000),
        textTheme: CupertinoTextThemeData(
          textStyle: baseText,
          actionTextStyle: baseText,
          navTitleTextStyle: TextStyle(
            fontFamily: 'Segoe UI Variable Display',
            fontFamilyFallback: ['Segoe UI', 'Segoe UI Emoji'],
            color: _ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
      ),
      home: PanelPage(store: store, state: state),
    );
  }
}

class PanelPage extends StatefulWidget {
  const PanelPage({required this.store, required this.state, super.key});

  final PanelStore store;
  final PanelState state;

  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> with WindowListener {
  late final TextEditingController _noteController;
  final FocusNode _keyboardFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  String? _saveError;

  PanelState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: state.note);
    _noteController.addListener(_noteChanged);
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _noteController
      ..removeListener(_noteChanged)
      ..dispose();
    _keyboardFocus.dispose();
    _scrollController.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  void _noteChanged() {
    state.note = _noteController.text;
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), _saveNow);
  }

  Future<void> _saveNow() async {
    try {
      await widget.store.save(state);
      if (mounted && _saveError != null) {
        setState(() => _saveError = null);
      }
    } on Object {
      if (mounted) {
        setState(() => _saveError = 'Could not save beside the app');
      }
    }
  }

  void _addTask() {
    setState(() {
      state.items.add(TaskItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: '',
      ));
    });
    _scheduleSave();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _removeTask(TaskItem item) {
    setState(() => state.items.remove(item));
    _scheduleSave();
  }

  void _clearCompleted() {
    setState(() => state.items.removeWhere((item) => item.done));
    _scheduleSave();
  }

  Future<void> _togglePin() async {
    state.alwaysOnTop = !state.alwaysOnTop;
    await windowManager.setAlwaysOnTop(state.alwaysOnTop);
    if (mounted) {
      setState(() {});
    }
    _scheduleSave();
  }

  @override
  void onWindowMove() => _captureWindowBounds();

  @override
  void onWindowResize() => _captureWindowBounds();

  Future<void> _captureWindowBounds() async {
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    state
      ..x = position.dx
      ..y = position.dy
      ..width = size.width
      ..height = size.height;
    _scheduleSave();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      _addTask();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final completed = state.items.where((item) => item.done).length;

    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: CupertinoPageScaffold(
        backgroundColor: const Color(0x00000000),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xB8FAF9F5),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0x8AFFFFFF), width: 0.8),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x2A000000),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Column(
                children: [
                  _Header(
                    pinned: state.alwaysOnTop,
                    completed: completed,
                    onTogglePin: _togglePin,
                    onClearCompleted: completed == 0 ? null : _clearCompleted,
                  ),
                  const Divider(height: 1, thickness: 0.6, color: _hairline),
                  Expanded(
                    child: CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                            child: CupertinoTextField(
                              controller: _noteController,
                              minLines: 2,
                              maxLines: 8,
                              placeholder: 'Write a note…  ✨',
                              placeholderStyle: const TextStyle(
                                color: Color(0xFFAAA9A4),
                                fontSize: 15,
                              ),
                              style: const TextStyle(
                                fontFamily: 'Segoe UI Variable',
                                fontFamilyFallback: ['Segoe UI', 'Segoe UI Emoji'],
                                color: _ink,
                                fontSize: 15,
                                height: 1.42,
                                letterSpacing: -0.1,
                              ),
                              padding: EdgeInsets.zero,
                              decoration: const BoxDecoration(),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                            child: Row(
                              children: [
                                const Text(
                                  'CHECKLIST',
                                  style: TextStyle(
                                    color: _secondaryInk,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                const Spacer(),
                                if (state.items.isNotEmpty)
                                  Text(
                                    '$completed/${state.items.length}',
                                    style: const TextStyle(
                                      color: _secondaryInk,
                                      fontSize: 11,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (state.items.isEmpty)
                          const SliverToBoxAdapter(child: _EmptyChecklist())
                        else
                          SliverList.builder(
                            itemCount: state.items.length,
                            itemBuilder: (context, index) {
                              final item = state.items[index];
                              return _TaskRow(
                                key: ValueKey(item.id),
                                item: item,
                                autofocus: item.text.isEmpty && index == state.items.length - 1,
                                onChanged: _scheduleSave,
                                onRemove: () => _removeTask(item),
                              );
                            },
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              alignment: Alignment.centerLeft,
                              onPressed: _addTask,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.add, size: 17),
                                  SizedBox(width: 6),
                                  Text('New item', style: TextStyle(fontSize: 14)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_saveError != null)
                    Container(
                      width: double.infinity,
                      color: const Color(0x1FFF3B30),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      child: Text(
                        '$_saveError · ${widget.store.displayPath}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFFB3261E), fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.pinned,
    required this.completed,
    required this.onTogglePin,
    required this.onClearCompleted,
  });

  final bool pinned;
  final int completed;
  final VoidCallback onTogglePin;
  final VoidCallback? onClearCompleted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: SizedBox(
        height: 54,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              const Text(
                'Sticky Panel',
                style: TextStyle(
                  color: _ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.25,
                ),
              ),
              const SizedBox(width: 8),
              if (pinned)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0x180A84FF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'PINNED',
                    style: TextStyle(
                      color: _blue,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              const Spacer(),
              if (completed > 0)
                _HeaderButton(
                  tooltip: 'Clear completed',
                  icon: CupertinoIcons.check_mark_circled,
                  onPressed: onClearCompleted,
                ),
              _HeaderButton(
                tooltip: pinned ? 'Stop keeping on top' : 'Keep on top',
                icon: pinned ? CupertinoIcons.pin_fill : CupertinoIcons.pin,
                selected: pinned,
                onPressed: onTogglePin,
              ),
              _HeaderButton(
                tooltip: 'Minimize',
                icon: CupertinoIcons.minus,
                onPressed: windowManager.minimize,
              ),
              _HeaderButton(
                tooltip: 'Close',
                icon: CupertinoIcons.xmark,
                onPressed: windowManager.close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatefulWidget {
  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: CupertinoButton(
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          onPressed: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.selected
                  ? const Color(0x170A84FF)
                  : _hovered
                      ? const Color(0x0F000000)
                      : const Color(0x00000000),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: widget.selected ? _blue : const Color(0xFF676762),
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    required this.item,
    required this.onChanged,
    required this.onRemove,
    required this.autofocus,
    super.key,
  });

  final TaskItem item;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final bool autofocus;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  late final TextEditingController _controller;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CupertinoButton(
              minimumSize: const Size(38, 38),
              padding: const EdgeInsets.all(8),
              onPressed: () {
                setState(() => widget.item.done = !widget.item.done);
                widget.onChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.item.done ? _blue : const Color(0x00000000),
                  border: Border.all(
                    color: widget.item.done ? _blue : const Color(0xFFAAA9A4),
                    width: 1.3,
                  ),
                ),
                child: widget.item.done
                    ? const Icon(CupertinoIcons.check_mark, color: CupertinoColors.white, size: 13)
                    : null,
              ),
            ),
            Expanded(
              child: CupertinoTextField(
                controller: _controller,
                autofocus: widget.autofocus,
                minLines: 1,
                maxLines: 3,
                placeholder: 'Something to do',
                placeholderStyle: const TextStyle(color: Color(0xFFB7B5B0), fontSize: 14),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(),
                style: TextStyle(
                  fontFamily: 'Segoe UI Variable',
                  fontFamilyFallback: const ['Segoe UI', 'Segoe UI Emoji'],
                  color: widget.item.done ? const Color(0xFF999893) : _ink,
                  fontSize: 14,
                  height: 1.3,
                  decoration: widget.item.done ? TextDecoration.lineThrough : TextDecoration.none,
                  decorationColor: const Color(0xFF999893),
                ),
                onChanged: (value) {
                  widget.item.text = value;
                  widget.onChanged();
                },
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: _hovered ? 1 : 0,
              child: CupertinoButton(
                minimumSize: const Size(30, 30),
                padding: EdgeInsets.zero,
                onPressed: widget.onRemove,
                child: const Icon(
                  CupertinoIcons.xmark_circle_fill,
                  size: 17,
                  color: Color(0xFFB5B3AD),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChecklist extends StatelessWidget {
  const _EmptyChecklist();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0x0A000000),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          children: [
            Icon(CupertinoIcons.check_mark_circled, size: 19, color: Color(0xFF9C9B96)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Nothing here yet. Add an item or press Ctrl + Enter.',
                style: TextStyle(color: _secondaryInk, fontSize: 12.5, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
