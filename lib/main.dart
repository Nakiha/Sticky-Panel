import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Divider, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'model/panel_state.dart';
import 'services/panel_store.dart';

const _blue = Color(0xFF0A84FF);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await acrylic.Window.initialize();
  await windowManager.ensureInitialized();

  final store = PanelStore();
  final state = await store.load();
  final initialSize = Size(
    state.width.clamp(340, 900).toDouble(),
    state.height.clamp(420, 1200).toDouble(),
  );
  final systemBrightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  final brightness = _resolvedBrightness(state.themeMode, systemBrightness);

  final options = WindowOptions(
    size: initialSize,
    minimumSize: const Size(340, 420),
    center: state.x == null || state.y == null,
    backgroundColor: const Color(0x00000000),
    skipTaskbar: false,
    title: state.title.trim().isEmpty ? 'StickPanel' : state.title.trim(),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    if (state.x != null && state.y != null) {
      await windowManager.setPosition(Offset(state.x!, state.y!));
    }
    await windowManager.setAlwaysOnTop(state.alwaysOnTop);
    await _setAcrylic(brightness);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(StickPanelApp(store: store, state: state));
}

Brightness _resolvedBrightness(String mode, Brightness systemBrightness) {
  if (mode == 'light') return Brightness.light;
  if (mode == 'dark') return Brightness.dark;
  return systemBrightness;
}

Future<void> _setAcrylic(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return acrylic.Window.setEffect(
    effect: acrylic.WindowEffect.acrylic,
    color: dark ? const Color(0xD21A1A1D) : const Color(0xD8F3F0E9),
    dark: dark,
  );
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
    return CupertinoApp(
      title: 'StickPanel',
      debugShowCheckedModeBanner: false,
      theme: const CupertinoThemeData(
        primaryColor: _blue,
        scaffoldBackgroundColor: Color(0x00000000),
        barBackgroundColor: Color(0x00000000),
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
  late final TextEditingController _titleController;
  late final TextEditingController _noteController;
  final FocusNode _keyboardFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  String? _saveError;
  bool _settingsOpen = false;
  Brightness? _lastBrightness;

  PanelState get state => widget.state;

  AppStrings get strings {
    final systemLanguage =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    final useChinese = state.language == 'zh' ||
        (state.language == 'system' && systemLanguage == 'zh');
    return AppStrings(useChinese);
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: state.title)
      ..addListener(_titleChanged);
    _noteController = TextEditingController(text: state.note)
      ..addListener(_noteChanged);
    windowManager.addListener(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = _resolvedBrightness(
      state.themeMode,
      MediaQuery.platformBrightnessOf(context),
    );
    if (_lastBrightness != brightness) {
      _lastBrightness = brightness;
      unawaited(_setAcrylic(brightness));
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _titleController
      ..removeListener(_titleChanged)
      ..dispose();
    _noteController
      ..removeListener(_noteChanged)
      ..dispose();
    _keyboardFocus.dispose();
    _scrollController.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  void _titleChanged() {
    state.title = _titleController.text;
    final title = state.title.trim();
    unawaited(windowManager.setTitle(title.isEmpty ? 'StickPanel' : title));
    _scheduleSave();
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
        setState(() => _saveError = strings.saveError);
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

  void _taskChanged() {
    setState(() {});
    _scheduleSave();
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
    if (mounted) setState(() {});
    _scheduleSave();
  }

  void _setThemeMode(String value) {
    setState(() => state.themeMode = value);
    final brightness = _resolvedBrightness(
      value,
      MediaQuery.platformBrightnessOf(context),
    );
    _lastBrightness = brightness;
    unawaited(_setAcrylic(brightness));
    _scheduleSave();
  }

  void _setLanguage(String value) {
    setState(() => state.language = value);
    if (state.title.trim().isEmpty) {
      unawaited(windowManager.setTitle(strings.untitled));
    }
    _scheduleSave();
  }

  void _setFontSize(double value) {
    setState(() => state.fontSize = value.clamp(12, 22).toDouble());
    _scheduleSave();
  }

  void _setFontWeight(int value) {
    setState(() => state.fontWeight = value);
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
    final brightness = _resolvedBrightness(
      state.themeMode,
      MediaQuery.platformBrightnessOf(context),
    );
    final palette = PanelPalette(brightness == Brightness.dark);
    final textWeight = _weightFromValue(state.fontWeight);
    final labels = strings;

    final theme = CupertinoThemeData(
      brightness: brightness,
      primaryColor: _blue,
      scaffoldBackgroundColor: const Color(0x00000000),
      barBackgroundColor: const Color(0x00000000),
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontFamily: 'Segoe UI Variable',
          fontFamilyFallback: const ['Segoe UI', 'Segoe UI Emoji'],
          color: palette.ink,
          fontSize: state.fontSize,
        ),
      ),
    );

    return CupertinoTheme(
      data: theme,
      child: Focus(
        focusNode: _keyboardFocus,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: CupertinoPageScaffold(
          backgroundColor: const Color(0x00000000),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.windowSurface,
              border: Border.all(color: palette.windowBorder, width: 0.7),
            ),
            child: Column(
              children: [
                _WindowBar(
                  palette: palette,
                  labels: labels,
                  pinned: state.alwaysOnTop,
                  settingsOpen: _settingsOpen,
                  completed: state.completedCount,
                  onToggleSettings: () =>
                      setState(() => _settingsOpen = !_settingsOpen),
                  onTogglePin: _togglePin,
                  onClearCompleted:
                      state.completedCount == 0 ? null : _clearCompleted,
                ),
                Divider(height: 1, thickness: 0.6, color: palette.separator),
                if (_settingsOpen)
                  _AppearancePanel(
                    palette: palette,
                    labels: labels,
                    state: state,
                    onThemeChanged: _setThemeMode,
                    onLanguageChanged: _setLanguage,
                    onFontSizeChanged: _setFontSize,
                    onFontWeightChanged: _setFontWeight,
                  ),
                Expanded(
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 2),
                          child: CupertinoTextField(
                            controller: _titleController,
                            maxLines: 2,
                            placeholder: labels.untitled,
                            placeholderStyle: TextStyle(
                              color: palette.tertiaryInk,
                              fontSize: state.fontSize + 5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.45,
                            ),
                            style: TextStyle(
                              fontFamily: 'Segoe UI Variable Display',
                              fontFamilyFallback: const [
                                'Segoe UI',
                                'Segoe UI Emoji',
                              ],
                              color: palette.ink,
                              fontSize: state.fontSize + 5,
                              fontWeight: textWeight,
                              height: 1.18,
                              letterSpacing: -0.45,
                            ),
                            padding: EdgeInsets.zero,
                            decoration: const BoxDecoration(),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _NoteCard(
                          controller: _noteController,
                          palette: palette,
                          labels: labels,
                          fontSize: state.fontSize,
                          fontWeight: textWeight,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _ChecklistHeader(
                          palette: palette,
                          labels: labels,
                          completed: state.completedCount,
                          total: state.items.length,
                        ),
                      ),
                      if (state.items.isEmpty)
                        SliverToBoxAdapter(
                          child: _EmptyChecklist(
                            palette: palette,
                            labels: labels,
                          ),
                        )
                      else
                        SliverList.builder(
                          itemCount: state.items.length,
                          itemBuilder: (context, index) {
                            final item = state.items[index];
                            return _TaskRow(
                              key: ValueKey(item.id),
                              item: item,
                              palette: palette,
                              labels: labels,
                              fontSize: state.fontSize,
                              fontWeight: textWeight,
                              autofocus: item.text.isEmpty &&
                                  index == state.items.length - 1,
                              onTextChanged: _scheduleSave,
                              onStateChanged: _taskChanged,
                              onRemove: () => _removeTask(item),
                            );
                          },
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
                          child: CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 9,
                            ),
                            alignment: Alignment.centerLeft,
                            onPressed: _addTask,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(CupertinoIcons.add, size: 17),
                                const SizedBox(width: 6),
                                Text(
                                  labels.newItem,
                                  style: const TextStyle(fontSize: 14),
                                ),
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
                    color: palette.errorSurface,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    child: Text(
                      '$_saveError · ${widget.store.displayPath}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.error, fontSize: 11),
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

class _WindowBar extends StatelessWidget {
  const _WindowBar({
    required this.palette,
    required this.labels,
    required this.pinned,
    required this.settingsOpen,
    required this.completed,
    required this.onToggleSettings,
    required this.onTogglePin,
    required this.onClearCompleted,
  });

  final PanelPalette palette;
  final AppStrings labels;
  final bool pinned;
  final bool settingsOpen;
  final int completed;
  final VoidCallback onToggleSettings;
  final VoidCallback onTogglePin;
  final VoidCallback? onClearCompleted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 43,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: windowManager.isMaximized,
              child: Align(
                alignment: Alignment.center,
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: palette.dragHandle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          if (completed > 0)
            _HeaderButton(
              palette: palette,
              tooltip: labels.clearCompleted,
              icon: CupertinoIcons.check_mark_circled,
              onPressed: onClearCompleted,
            ),
          _HeaderButton(
            palette: palette,
            tooltip: labels.appearance,
            icon: CupertinoIcons.slider_horizontal_3,
            selected: settingsOpen,
            onPressed: onToggleSettings,
          ),
          _HeaderButton(
            palette: palette,
            tooltip: pinned ? labels.unpin : labels.pin,
            icon: pinned ? CupertinoIcons.pin_fill : CupertinoIcons.pin,
            selected: pinned,
            onPressed: onTogglePin,
          ),
          _HeaderButton(
            palette: palette,
            tooltip: labels.minimize,
            icon: CupertinoIcons.minus,
            onPressed: windowManager.minimize,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _HeaderButton(
              palette: palette,
              tooltip: labels.close,
              icon: CupertinoIcons.xmark,
              dangerOnHover: true,
              onPressed: windowManager.close,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatefulWidget {
  const _HeaderButton({
    required this.palette,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.dangerOnHover = false,
  });

  final PanelPalette palette;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool dangerOnHover;

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final danger = _hovered && widget.dangerOnHover;
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
            width: 29,
            height: 29,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: danger
                  ? const Color(0xFFFF453A)
                  : widget.selected
                      ? widget.palette.selectedSurface
                      : _hovered
                          ? widget.palette.hoverSurface
                          : const Color(0x00000000),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: danger
                  ? CupertinoColors.white
                  : widget.selected
                      ? _blue
                      : widget.palette.secondaryInk,
            ),
          ),
        ),
      ),
    );
  }
}

class _AppearancePanel extends StatelessWidget {
  const _AppearancePanel({
    required this.palette,
    required this.labels,
    required this.state,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.onFontSizeChanged,
    required this.onFontWeightChanged,
  });

  final PanelPalette palette;
  final AppStrings labels;
  final PanelState state;
  final ValueChanged<String> onThemeChanged;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<int> onFontWeightChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.cardBorder, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            labels.appearance,
            style: TextStyle(
              color: palette.ink,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 11),
          _SettingRow(
            label: labels.theme,
            palette: palette,
            child: CupertinoSlidingSegmentedControl<String>(
              groupValue: state.themeMode,
              thumbColor: palette.segmentThumb,
              backgroundColor: palette.segmentTrack,
              onValueChanged: (value) {
                if (value != null) onThemeChanged(value);
              },
              children: {
                'system': _SegmentLabel(labels.system),
                'light': _SegmentLabel(labels.light),
                'dark': _SegmentLabel(labels.dark),
              },
            ),
          ),
          const SizedBox(height: 9),
          _SettingRow(
            label: labels.language,
            palette: palette,
            child: CupertinoSlidingSegmentedControl<String>(
              groupValue: state.language,
              thumbColor: palette.segmentThumb,
              backgroundColor: palette.segmentTrack,
              onValueChanged: (value) {
                if (value != null) onLanguageChanged(value);
              },
              children: {
                'system': _SegmentLabel(labels.system),
                'zh': const _SegmentLabel('中文'),
                'en': const _SegmentLabel('EN'),
              },
            ),
          ),
          const SizedBox(height: 9),
          _SettingRow(
            label: labels.textSize,
            palette: palette,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StepperButton(
                  palette: palette,
                  label: 'A−',
                  onPressed: state.fontSize <= 12
                      ? null
                      : () => onFontSizeChanged(state.fontSize - 1),
                ),
                SizedBox(
                  width: 32,
                  child: Text(
                    state.fontSize.round().toString(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.secondaryInk,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                _StepperButton(
                  palette: palette,
                  label: 'A+',
                  onPressed: state.fontSize >= 22
                      ? null
                      : () => onFontSizeChanged(state.fontSize + 1),
                ),
              ],
            ),
          ),
          const SizedBox(height: 9),
          _SettingRow(
            label: labels.fontWeight,
            palette: palette,
            child: CupertinoSlidingSegmentedControl<int>(
              groupValue: state.fontWeight,
              thumbColor: palette.segmentThumb,
              backgroundColor: palette.segmentTrack,
              onValueChanged: (value) {
                if (value != null) onFontWeightChanged(value);
              },
              children: {
                400: _SegmentLabel(labels.regular),
                600: _SegmentLabel(labels.semibold),
                700: _SegmentLabel(labels.bold),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.palette,
    required this.child,
  });

  final String label;
  final PanelPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: TextStyle(color: palette.secondaryInk, fontSize: 12),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.palette,
    required this.label,
    required this.onPressed,
  });

  final PanelPalette palette;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      minimumSize: const Size(34, 28),
      padding: EdgeInsets.zero,
      color: palette.segmentTrack,
      disabledColor: palette.segmentTrack,
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          color: onPressed == null ? palette.tertiaryInk : palette.ink,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.controller,
    required this.palette,
    required this.labels,
    required this.fontSize,
    required this.fontWeight,
  });

  final TextEditingController controller;
  final PanelPalette palette;
  final AppStrings labels;
  final double fontSize;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: palette.cardBorder, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            labels.note,
            style: TextStyle(
              color: palette.secondaryInk,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 7),
          CupertinoTextField(
            controller: controller,
            minLines: 2,
            maxLines: 7,
            placeholder: labels.notePlaceholder,
            placeholderStyle: TextStyle(
              color: palette.tertiaryInk,
              fontSize: fontSize,
            ),
            style: TextStyle(
              fontFamily: 'Segoe UI Variable',
              fontFamilyFallback: const ['Segoe UI', 'Segoe UI Emoji'],
              color: palette.ink,
              fontSize: fontSize,
              fontWeight: fontWeight,
              height: 1.42,
              letterSpacing: -0.1,
            ),
            padding: EdgeInsets.zero,
            decoration: const BoxDecoration(),
          ),
        ],
      ),
    );
  }
}

class _ChecklistHeader extends StatelessWidget {
  const _ChecklistHeader({
    required this.palette,
    required this.labels,
    required this.completed,
    required this.total,
  });

  final PanelPalette palette;
  final AppStrings labels;
  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final progress = total == 0 ? 0.0 : completed / total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 13, 20, 8),
      child: Row(
        children: [
          Text(
            labels.checklist,
            style: TextStyle(
              color: palette.secondaryInk,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const Spacer(),
          if (total > 0) ...[
            SizedBox(
              width: 62,
              height: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: [
                        Container(color: palette.progressTrack),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: constraints.maxWidth * progress,
                          color: _blue,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$completed/$total',
              style: TextStyle(
                color: palette.secondaryInk,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    required this.item,
    required this.palette,
    required this.labels,
    required this.fontSize,
    required this.fontWeight,
    required this.onTextChanged,
    required this.onStateChanged,
    required this.onRemove,
    required this.autofocus,
    super.key,
  });

  final TaskItem item;
  final PanelPalette palette;
  final AppStrings labels;
  final double fontSize;
  final FontWeight fontWeight;
  final VoidCallback onTextChanged;
  final VoidCallback onStateChanged;
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

  Future<void> _choosePriority() async {
    final selected = await showCupertinoModalPopup<TaskPriority>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(widget.labels.priority),
        actions: TaskPriority.values.map((priority) {
          return CupertinoActionSheetAction(
            isDefaultAction: priority == widget.item.priority,
            onPressed: () => Navigator.of(context).pop(priority),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: _priorityColor(priority, widget.palette),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Text(widget.labels.priorityName(priority)),
              ],
            ),
          );
        }).toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.labels.cancel),
        ),
      ),
    );
    if (selected != null && selected != widget.item.priority) {
      widget.item.priority = selected;
      widget.onStateChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        decoration: BoxDecoration(
          color: _hovered ? palette.hoverSurface : const Color(0x00000000),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CupertinoButton(
              minimumSize: const Size(38, 42),
              padding: const EdgeInsets.all(8),
              onPressed: () {
                widget.item.done = !widget.item.done;
                widget.onStateChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.item.done ? _blue : const Color(0x00000000),
                  border: Border.all(
                    color: widget.item.done ? _blue : palette.checkboxBorder,
                    width: 1.3,
                  ),
                ),
                child: widget.item.done
                    ? const Icon(
                        CupertinoIcons.check_mark,
                        color: CupertinoColors.white,
                        size: 13,
                      )
                    : null,
              ),
            ),
            Expanded(
              child: CupertinoTextField(
                controller: _controller,
                autofocus: widget.autofocus,
                minLines: 1,
                maxLines: 3,
                placeholder: widget.labels.taskPlaceholder,
                placeholderStyle: TextStyle(
                  color: palette.tertiaryInk,
                  fontSize: widget.fontSize,
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(),
                style: TextStyle(
                  fontFamily: 'Segoe UI Variable',
                  fontFamilyFallback: const ['Segoe UI', 'Segoe UI Emoji'],
                  color: widget.item.done ? palette.completedInk : palette.ink,
                  fontSize: widget.fontSize,
                  fontWeight: widget.fontWeight,
                  height: 1.3,
                  decoration: widget.item.done
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                  decorationColor: palette.completedInk,
                ),
                onChanged: (value) {
                  widget.item.text = value;
                  widget.onTextChanged();
                },
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
            ),
            Tooltip(
              message:
                  '${widget.labels.priority}: ${widget.labels.priorityName(widget.item.priority)}',
              child: CupertinoButton(
                minimumSize: const Size(30, 36),
                padding: const EdgeInsets.all(7),
                onPressed: _choosePriority,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: widget.item.priority == TaskPriority.normal ? 8 : 17,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _priorityColor(widget.item.priority, palette),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              ignoring: !_hovered,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: _hovered ? 1 : 0,
                child: CupertinoButton(
                  minimumSize: const Size(30, 36),
                  padding: EdgeInsets.zero,
                  onPressed: widget.onRemove,
                  child: Icon(
                    CupertinoIcons.xmark_circle_fill,
                    size: 17,
                    color: palette.tertiaryInk,
                  ),
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
  const _EmptyChecklist({required this.palette, required this.labels});

  final PanelPalette palette;
  final AppStrings labels;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 5, 14, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.cardBorder, width: 0.7),
        ),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.check_mark_circled,
              size: 19,
              color: palette.secondaryInk,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                labels.emptyChecklist,
                style: TextStyle(
                  color: palette.secondaryInk,
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

FontWeight _weightFromValue(int value) {
  if (value >= 700) return FontWeight.w700;
  if (value >= 600) return FontWeight.w600;
  return FontWeight.w400;
}

Color _priorityColor(TaskPriority priority, PanelPalette palette) {
  return switch (priority) {
    TaskPriority.low => const Color(0xFF64A8FF),
    TaskPriority.normal => palette.tertiaryInk,
    TaskPriority.high => const Color(0xFFFF9F0A),
    TaskPriority.urgent => const Color(0xFFFF453A),
  };
}

class PanelPalette {
  const PanelPalette(this.dark);

  final bool dark;

  Color get ink => dark ? const Color(0xFFF5F5F7) : const Color(0xFF202124);
  Color get secondaryInk =>
      dark ? const Color(0xFFA7A7AD) : const Color(0xFF73736F);
  Color get tertiaryInk =>
      dark ? const Color(0xFF74747A) : const Color(0xFFAAA9A4);
  Color get completedInk =>
      dark ? const Color(0xFF77777D) : const Color(0xFF999893);
  Color get windowSurface =>
      dark ? const Color(0x75151518) : const Color(0x66FAF9F5);
  Color get windowBorder =>
      dark ? const Color(0x38FFFFFF) : const Color(0x70FFFFFF);
  Color get separator =>
      dark ? const Color(0x2BFFFFFF) : const Color(0x204A4A45);
  Color get card =>
      dark ? const Color(0x3DFFFFFF) : const Color(0x66FFFFFF);
  Color get cardBorder =>
      dark ? const Color(0x2EFFFFFF) : const Color(0x78FFFFFF);
  Color get hoverSurface =>
      dark ? const Color(0x18FFFFFF) : const Color(0x0F000000);
  Color get selectedSurface =>
      dark ? const Color(0x340A84FF) : const Color(0x180A84FF);
  Color get dragHandle =>
      dark ? const Color(0x45FFFFFF) : const Color(0x28000000);
  Color get checkboxBorder =>
      dark ? const Color(0xFF77777D) : const Color(0xFFAAA9A4);
  Color get progressTrack =>
      dark ? const Color(0x24FFFFFF) : const Color(0x18000000);
  Color get segmentTrack =>
      dark ? const Color(0x2BFFFFFF) : const Color(0x10000000);
  Color get segmentThumb =>
      dark ? const Color(0xFF4A4A4F) : const Color(0xFFFFFFFF);
  Color get errorSurface =>
      dark ? const Color(0x33FF453A) : const Color(0x1FFF3B30);
  Color get error =>
      dark ? const Color(0xFFFF6961) : const Color(0xFFB3261E);
}

class AppStrings {
  const AppStrings(this.zh);

  final bool zh;

  String get untitled => zh ? '未命名清单' : 'Untitled list';
  String get note => zh ? '备注' : 'NOTE';
  String get notePlaceholder => zh ? '写下一些补充内容…  ✨' : 'Add a note…  ✨';
  String get checklist => zh ? '待办事项' : 'TO DO';
  String get newItem => zh ? '新建任务' : 'New task';
  String get taskPlaceholder => zh ? '要做什么？' : 'What needs doing?';
  String get emptyChecklist => zh
      ? '还没有任务。点击“新建任务”，或按 Ctrl + Enter。'
      : 'No tasks yet. Add one or press Ctrl + Enter.';
  String get clearCompleted => zh ? '清除已完成' : 'Clear completed';
  String get pin => zh ? '保持置顶' : 'Keep on top';
  String get unpin => zh ? '取消置顶' : 'Stop keeping on top';
  String get minimize => zh ? '最小化' : 'Minimize';
  String get close => zh ? '关闭' : 'Close';
  String get appearance => zh ? '外观与文本' : 'Appearance & text';
  String get theme => zh ? '主题' : 'Theme';
  String get system => zh ? '跟随系统' : 'System';
  String get light => zh ? '浅色' : 'Light';
  String get dark => zh ? '深色' : 'Dark';
  String get language => zh ? '语言' : 'Language';
  String get textSize => zh ? '字号' : 'Size';
  String get fontWeight => zh ? '字重' : 'Weight';
  String get regular => zh ? '常规' : 'Regular';
  String get semibold => zh ? '中等' : 'Medium';
  String get bold => zh ? '粗体' : 'Bold';
  String get priority => zh ? '优先级' : 'Priority';
  String get cancel => zh ? '取消' : 'Cancel';
  String get saveError => zh ? '无法保存到程序目录' : 'Could not save beside the app';

  String priorityName(TaskPriority priority) {
    if (zh) {
      return switch (priority) {
        TaskPriority.low => '低',
        TaskPriority.normal => '普通',
        TaskPriority.high => '高',
        TaskPriority.urgent => '紧急',
      };
    }
    return switch (priority) {
      TaskPriority.low => 'Low',
      TaskPriority.normal => 'Normal',
      TaskPriority.high => 'High',
      TaskPriority.urgent => 'Urgent',
    };
  }
}
