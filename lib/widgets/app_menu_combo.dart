import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A compact app-styled menu button.
///
/// Menu ownership is deliberately delegated to Flutter's [MenuAnchor].  The
/// previous implementation inserted and animated its own [OverlayEntry]. That
/// made the menu outlive the selection panel that launched it and allowed
/// close/rebuild races to leave stale menu layers on screen.
class AppMenuCombo<T> extends StatefulWidget {
  final T value;
  final List<T> items;
  final String Function(T value) labelFor;
  final ValueChanged<T> onChanged;
  final Widget Function(BuildContext context, T value, bool open)?
  buttonBuilder;
  final Widget Function(
    BuildContext context,
    T value,
    String label,
    bool selected,
  )?
  itemBuilder;
  final double? width;
  final double height;
  final double itemHeight;
  final double? minMenuWidth;
  final double maxMenuWidth;
  final EdgeInsetsGeometry buttonPadding;
  final EdgeInsetsGeometry itemPadding;
  final BorderRadius borderRadius;
  final BoxBorder? border;
  final Color? backgroundColor;
  final TextStyle? textStyle;
  final TextStyle? menuTextStyle;
  final double iconSize;
  final String? buttonLabel;
  final IconData? buttonLeadingIcon;
  final Color? foregroundColor;
  final bool showSelectedCheck;
  final IconData? Function(T value)? iconFor;
  final bool notifyOnReselect;
  final bool enabled;
  final Listenable? closeListenable;

  const AppMenuCombo({
    super.key,
    required this.value,
    required this.items,
    required this.labelFor,
    required this.onChanged,
    this.buttonBuilder,
    this.itemBuilder,
    this.width,
    this.height = 32,
    this.itemHeight = 36,
    this.minMenuWidth,
    this.maxMenuWidth = 520,
    this.buttonPadding = const EdgeInsets.symmetric(horizontal: 8),
    this.itemPadding = const EdgeInsets.only(left: 12, right: 16),
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
    this.border,
    this.backgroundColor,
    this.textStyle,
    this.menuTextStyle,
    this.iconSize = 18,
    this.buttonLabel,
    this.buttonLeadingIcon,
    this.foregroundColor,
    this.showSelectedCheck = true,
    this.iconFor,
    this.notifyOnReselect = false,
    this.enabled = true,
    this.closeListenable,
  });

  @override
  State<AppMenuCombo<T>> createState() => _AppMenuComboState<T>();
}

class _AppMenuComboState<T> extends State<AppMenuCombo<T>> {
  final _menuController = MenuController();
  final _focusNode = FocusNode(debugLabel: 'AppMenuCombo');

  static const _menuGap = 4.0;
  static const _menuVerticalPadding = 4.0;
  static const _leadingWidth = 20.0;
  static const _leadingGap = 8.0;

  bool get _isOpen => _menuController.isOpen;

  @override
  void initState() {
    super.initState();
    widget.closeListenable?.addListener(_closeMenu);
  }

  @override
  void didUpdateWidget(covariant AppMenuCombo<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.closeListenable != widget.closeListenable) {
      oldWidget.closeListenable?.removeListener(_closeMenu);
      widget.closeListenable?.addListener(_closeMenu);
    }
    if (!widget.enabled && _isOpen) {
      _closeMenu();
    }
  }

  @override
  void dispose() {
    widget.closeListenable?.removeListener(_closeMenu);
    _closeMenu();
    _focusNode.dispose();
    super.dispose();
  }

  void _closeMenu() {
    if (_isOpen) _menuController.close();
  }

  void _toggleMenu() {
    if (!widget.enabled) return;
    if (_isOpen) {
      _menuController.close();
    } else {
      _menuController.open();
    }
  }

  void _select(T item) {
    _menuController.close();
    if (widget.notifyOnReselect || item != widget.value) {
      widget.onChanged(item);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (!_isOpen &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      _menuController.open();
      return KeyEventResult.handled;
    }
    if (_isOpen && event.logicalKey == LogicalKeyboardKey.escape) {
      _menuController.close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  double _menuWidth(BuildContext context) {
    final direction = Directionality.of(context);
    final style =
        widget.menuTextStyle ??
        widget.textStyle ??
        Theme.of(context).textTheme.bodySmall ??
        const TextStyle();
    var labelWidth = 0.0;
    for (final item in widget.items) {
      final painter = TextPainter(
        text: TextSpan(text: widget.labelFor(item), style: style),
        textDirection: direction,
        maxLines: 1,
      )..layout();
      labelWidth = math.max(labelWidth, painter.width);
      painter.dispose();
    }
    final padding = widget.itemPadding.resolve(direction);
    final hasLeading =
        widget.showSelectedCheck ||
        widget.iconFor != null ||
        widget.itemBuilder != null;
    final contentWidth =
        labelWidth +
        padding.horizontal +
        (hasLeading ? _leadingWidth + _leadingGap : 0) +
        // Menu panels reserve a little horizontal space for focus/ink paint.
        // Without slack, a label that exactly fills the computed width can be
        // clipped when the selected row also paints its leading checkmark.
        8;
    final minWidth = math.max(widget.width ?? 0, widget.minMenuWidth ?? 0);
    final availableWidth = math.max(
      minWidth,
      MediaQuery.sizeOf(context).width - 16,
    );
    final maxWidth = math.max(
      minWidth,
      math.min(widget.maxMenuWidth, availableWidth),
    );
    return contentWidth.clamp(minWidth, maxWidth).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final menuWidth = _menuWidth(context);
    final maxMenuHeight = math.max(
      widget.itemHeight + _menuVerticalPadding * 2,
      MediaQuery.sizeOf(context).height - 16,
    );
    final labelStyle = (widget.textStyle ?? theme.textTheme.bodySmall)
        ?.copyWith(color: widget.foregroundColor);
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);
    final effectiveLabelStyle = widget.enabled
        ? labelStyle
        : labelStyle?.copyWith(color: disabledColor);
    final iconColor = widget.enabled
        ? widget.foregroundColor ?? theme.iconTheme.color
        : disabledColor;
    final label = widget.buttonLabel ?? widget.labelFor(widget.value);

    final anchor = SizedBox(
      width: widget.width,
      height: widget.height,
      child: Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.enabled ? _toggleMenu : null,
          borderRadius: widget.borderRadius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.backgroundColor,
              border: widget.border,
              borderRadius: widget.borderRadius,
            ),
            child: Padding(
              padding: widget.buttonPadding,
              child:
                  widget.buttonBuilder?.call(context, widget.value, _isOpen) ??
                  Row(
                    children: [
                      if (widget.buttonLeadingIcon != null) ...[
                        Icon(
                          widget.buttonLeadingIcon,
                          size: widget.iconSize,
                          color: iconColor,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          label,
                          style: effectiveLabelStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      AppMenuComboArrow(
                        open: _isOpen,
                        size: widget.iconSize,
                        color: iconColor,
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );

    return MenuAnchor(
      controller: _menuController,
      childFocusNode: _focusNode,
      alignmentOffset: const Offset(0, _menuGap),
      consumeOutsideTap: false,
      useRootOverlay: true,
      animated: false,
      onOpen: () {
        if (mounted) setState(() {});
      },
      onClose: () {
        if (mounted) setState(() {});
      },
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomStart,
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
        shadowColor: WidgetStatePropertyAll(
          scheme.shadow.withValues(alpha: 0.28),
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(6),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: _menuVerticalPadding),
        ),
        minimumSize: WidgetStatePropertyAll(Size(menuWidth, 0)),
        maximumSize: WidgetStatePropertyAll(Size(menuWidth, maxMenuHeight)),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      menuChildren: [
        for (final item in widget.items)
          _MenuOption<T>(
            value: item,
            label: widget.labelFor(item),
            selected: item == widget.value,
            width: menuWidth,
            height: widget.itemHeight,
            padding: widget.itemPadding,
            textStyle: widget.menuTextStyle,
            showSelectedCheck: widget.showSelectedCheck,
            icon: widget.iconFor?.call(item),
            customChild: widget.itemBuilder?.call(
              context,
              item,
              widget.labelFor(item),
              item == widget.value,
            ),
            onSelected: _select,
          ),
      ],
      builder: (context, controller, child) => Focus(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: child!,
      ),
      child: widget.width == null
          ? anchor
          : SizedBox(width: widget.width, child: anchor),
    );
  }
}

class AppMenuComboArrow extends StatelessWidget {
  final bool open;
  final double size;
  final Color? color;

  const AppMenuComboArrow({
    super.key,
    required this.open,
    this.size = 18,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: open ? 0.5 : 0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child: Icon(Icons.arrow_drop_down, size: size, color: color),
    );
  }
}

class _MenuOption<T> extends StatelessWidget {
  final T value;
  final String label;
  final bool selected;
  final double width;
  final double height;
  final EdgeInsetsGeometry padding;
  final TextStyle? textStyle;
  final bool showSelectedCheck;
  final IconData? icon;
  final Widget? customChild;
  final ValueChanged<T> onSelected;

  const _MenuOption({
    required this.value,
    required this.label,
    required this.selected,
    required this.width,
    required this.height,
    required this.padding,
    required this.textStyle,
    required this.showSelectedCheck,
    required this.icon,
    required this.customChild,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuItemButton(
      onPressed: () => onSelected(value),
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        minimumSize: WidgetStatePropertyAll(Size(width, height)),
        fixedSize: WidgetStatePropertyAll(Size(width, height)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: padding,
          child:
              customChild ??
              Row(
                children: [
                  if (showSelectedCheck || icon != null) ...[
                    SizedBox(
                      width: _AppMenuComboState._leadingWidth,
                      child: selected && showSelectedCheck
                          ? Icon(Icons.check, size: 16, color: scheme.primary)
                          : icon == null
                          ? null
                          : Icon(
                              icon,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                    ),
                    const SizedBox(width: _AppMenuComboState._leadingGap),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      style:
                          (textStyle ?? Theme.of(context).textTheme.bodySmall)
                              ?.copyWith(
                                color: selected
                                    ? scheme.primary
                                    : scheme.onSurface,
                              ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
        ),
      ),
    );
  }
}
