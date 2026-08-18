import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/src/editor/widgets/text/text_line.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sticky_panel/app.dart';
import 'package:sticky_panel/models.dart';
import 'package:sticky_panel/store.dart';
import 'package:sticky_panel/todos.dart';

void main() {
  test('project json round-trip preserves the document', () {
    final project = Project(
      id: 'p1',
      name: '项目A',
      docJson: '[{"insert":"hi\\n"}]',
    );
    final restored = Project.fromJson(jsonDecode(jsonEncode(project.toJson())));
    expect(restored.id, 'p1');
    expect(restored.name, '项目A');
    expect(restored.docJson, project.docJson);
  });

  test('remembered close preference survives a store reload', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AppStore();
    await first.load();
    await first.setClosePreference(ClosePreference.hideToTray);

    final second = AppStore();
    await second.load();
    expect(second.closePreference, ClosePreference.hideToTray);

    first.dispose();
    second.dispose();
  });

  test('parseTodoSpans finds open and done spans', () {
    final ops = [
      {'insert': '随便记点东西\n'},
      {
        'insert': '跟进合同',
        'attributes': {'todo': 'open', 'underline': true},
      },
      {'insert': '\n普通行\n'},
      {
        'insert': '已完成的事',
        'attributes': {'todo': 'done', 'underline': true, 'strike': true},
      },
      {'insert': '\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.length, 2);
    expect(spans[0].text, '跟进合同');
    expect(spans[0].done, isFalse);
    expect(spans[1].text, '已完成的事');
    expect(spans[1].done, isTrue);
  });

  test('parseTodoSpans groups by the nearest heading above', () {
    final ops = [
      {
        'insert': '无标题待办',
        'attributes': {'todo': 'open'},
      },
      {'insert': '\n'},
      {'insert': '客户端'},
      {
        'insert': '\n',
        'attributes': {'header': 2},
      },
      {
        'insert': '修崩溃',
        'attributes': {'todo': 'open'},
      },
      {'insert': '\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.length, 2);
    expect(spans[0].section, kUngroupedTitle);
    expect(spans[1].section, '客户端');
  });

  test('parseTodoSpans merges adjacent ops with the same state', () {
    final ops = [
      {
        'insert': '前半',
        'attributes': {'todo': 'open'},
      },
      {
        'insert': '后半',
        'attributes': {'todo': 'open', 'bold': true},
      },
      {'insert': '\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.length, 1);
    expect(spans[0].text, '前半后半');
    expect(spans[0].start, 0);
    expect(spans[0].length, 4);
  });

  test('parseTodoSpans splits spans when the done state changes', () {
    final ops = [
      {
        'insert': '甲乙',
        'attributes': {'todo': 'open'},
      },
      {
        'insert': '丙',
        'attributes': {'todo': 'done'},
      },
      {'insert': '\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.length, 2);
    expect(spans[0].text, '甲乙');
    expect(spans[1].text, '丙');
    expect(spans[1].start, 2);
  });

  test('span offsets match document positions', () {
    final ops = [
      {'insert': '前两字'},
      {'insert': '\n'},
      {
        'insert': '目标',
        'attributes': {'todo': 'open'},
      },
      {'insert': '尾巴\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.single.start, 4);
    expect(spans.single.length, 2);
  });

  test('typing inside a todo keeps it as one todo', () {
    SharedPreferences.setMockInitialValues({});
    const text = '今天很热要买冰淇淋';
    final project = Project(
      id: 'p1',
      name: '项目A',
      docJson: jsonEncode([
        {
          'insert': text,
          'attributes': {'todo': 'open'},
        },
        {'insert': '\n'},
      ]),
    );
    final store = AppStore()..projects.add(project);
    addTearDown(store.dispose);
    final controller = store.controllerFor(project);
    final insertAt = '今天很热'.length;

    controller.replaceText(
      insertAt,
      0,
      ' ',
      TextSelection.collapsed(offset: insertAt + 1),
    );

    final spans = parseTodoSpans(controller.document.toDelta().toJson());
    expect(spans, hasLength(1));
    expect(spans.single.text, '今天很热 要买冰淇淋');
    expect(spans.single.done, isFalse);
  });

  test('replacing text inside a completed todo preserves its state', () {
    SharedPreferences.setMockInitialValues({});
    final project = Project(
      id: 'p1',
      name: '项目A',
      docJson: jsonEncode([
        {
          'insert': '今天很热要买冰淇淋',
          'attributes': {'todo': 'done'},
        },
        {'insert': '\n'},
      ]),
    );
    final store = AppStore()..projects.add(project);
    addTearDown(store.dispose);
    final controller = store.controllerFor(project);

    controller.replaceText(
      2,
      2,
      '真的',
      const TextSelection.collapsed(offset: 4),
    );

    final spans = parseTodoSpans(controller.document.toDelta().toJson());
    expect(spans, hasLength(1));
    expect(spans.single.done, isTrue);
  });

  test('separately marked todos are not merged across plain text', () {
    SharedPreferences.setMockInitialValues({});
    const first = '今天很热';
    final project = Project(
      id: 'p1',
      name: '项目A',
      docJson: jsonEncode([
        {
          'insert': first,
          'attributes': {'todo': 'open'},
        },
        {'insert': ' '},
        {
          'insert': '要买冰淇淋',
          'attributes': {'todo': 'open'},
        },
        {'insert': '\n'},
      ]),
    );
    final store = AppStore()..projects.add(project);
    addTearDown(store.dispose);
    final controller = store.controllerFor(project);

    controller.replaceText(
      first.length,
      0,
      '-',
      TextSelection.collapsed(offset: first.length + 1),
    );

    final spans = parseTodoSpans(controller.document.toDelta().toJson());
    expect(spans, hasLength(2));
    expect(spans[0].text, first);
    expect(spans[1].text, '要买冰淇淋');
  });

  test('marking a multi-line selection skips heading lines', () {
    SharedPreferences.setMockInitialValues({});
    final project = Project(
      id: 'p1',
      name: '项目A',
      docJson: jsonEncode([
        {'insert': '标题'},
        {
          'insert': '\n',
          'attributes': {'header': 2},
        },
        {'insert': '第一项\n第二项\n'},
      ]),
    );
    final store = AppStore()..projects.add(project);
    addTearDown(store.dispose);
    final controller = store.controllerFor(project);

    store.markTodoSpan(project, 0, controller.document.length);

    final spans = parseTodoSpans(controller.document.toDelta().toJson());
    expect(spans.map((span) => span.text), ['第一项', '第二项']);
    expect(
      controller
          .document
          .collectStyle(0, 2)
          .attributes[kTodoAttributeKey],
      isNull,
    );
  });

  Future<AppStore> pumpTodoApp(
    WidgetTester tester, {
    String? documentJson,
    bool enableSystemTray = false,
  }) async {
    final document =
        documentJson ??
        jsonEncode([
          {'insert': '阶段一'},
          {
            'insert': '\n',
            'attributes': {'header': 2},
          },
          {
            'insert': '修复问题',
            'attributes': {'todo': 'open'},
          },
          {'insert': '\n'},
        ]);
    SharedPreferences.setMockInitialValues({
      'sticky_panel_data_v2': jsonEncode({
        'selectedIndex': 0,
        'projects': [
          {'id': 'p1', 'name': '项目A', 'docJson': document, 'colorValue': 0},
        ],
      }),
    });
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(
      StickyPanelApp(store: store, enableSystemTray: enableSystemTray),
    );
    await tester.pump();
    // The widget test binding tears down the rendered tree between tests.
    // Starting another guarded pump from addTearDown can overlap the next
    // test when Quill is still closing an overlay or text-input connection.
    addTearDown(store.dispose);
    return store;
  }

  testWidgets('todo header and group title use readable typography', (
    tester,
  ) async {
    await pumpTodoApp(tester);

    Text textWidget(String value) => tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((widget) => widget.data == value);

    expect(textWidget('待办').style?.fontSize, 14);
    expect(textWidget('剩余 1 / 共 1').style?.fontSize, 14);
    expect(textWidget('阶段一').style?.fontSize, 14);
    expect(textWidget('阶段一').style?.fontWeight, FontWeight.w700);
  });

  testWidgets('empty todo state is concise, padded, and uses the action icon', (
    tester,
  ) async {
    await pumpTodoApp(
      tester,
      documentJson: jsonEncode([
        {'insert': '普通内容\n'},
      ]),
    );

    final emptyState = find.byKey(const ValueKey('todo-empty-state'));
    final padding = tester.widget<Padding>(emptyState);
    final text = tester.widget<Text>(
      find.descendant(
        of: emptyState,
        matching: find.text('划选文字后列为待办'),
      ),
    );
    final icon = tester.widget<Icon>(
      find.descendant(of: emptyState, matching: find.byType(Icon)),
    );

    expect(
      padding.padding,
      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    );
    expect(text.style?.fontSize, 14);
    expect(icon.icon, Icons.playlist_add_check);
    expect(find.textContaining('在编辑板里划选'), findsNothing);
  });

  testWidgets('todo header drag resizes and clamps the panel', (tester) async {
    await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));
    final header = find.byKey(const ValueKey('todo-header'));

    expect(tester.getSize(panel).height, 180);
    await tester.drag(header, const Offset(0, -90));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(180));

    await tester.drag(header, const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 40);
  });

  testWidgets('todo header snaps directly at both ends of its drag range', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));
    final header = find.byKey(const ValueKey('todo-header'));
    final maxTodoHeight = tester.getSize(find.byType(Scaffold)).height - 36;
    const minTodoHeight = 40.0;
    final resizeTravel = maxTodoHeight - minTodoHeight;

    final nearTopHeight = minTodoHeight + resizeTravel * 0.995;
    await tester.drag(
      header,
      Offset(0, -(nearTopHeight - tester.getSize(panel).height)),
    );
    await tester.pump();
    expect(tester.getSize(panel).height, maxTodoHeight);
    expect(tester.widget<AnimatedContainer>(panel).duration, Duration.zero);
    expect(find.byTooltip('收起待办区'), findsOneWidget);

    final nearBottomHeight = minTodoHeight + resizeTravel * 0.005;
    await tester.drag(
      header,
      Offset(0, maxTodoHeight - nearBottomHeight),
    );
    await tester.pump();
    expect(tester.getSize(panel).height, minTodoHeight);
    expect(tester.widget<AnimatedContainer>(panel).duration, Duration.zero);
    expect(find.byTooltip('待办区占满面板'), findsOneWidget);
  });

  testWidgets('todo panel expands and collapses back to its previous height', (
    tester,
  ) async {
    await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));

    expect(tester.getSize(panel).height, 180);
    await tester.tap(find.byTooltip('待办区占满面板'));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(180));
    expect(find.byTooltip('收起待办区'), findsOneWidget);

    await tester.tap(find.byTooltip('收起待办区'));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 180);
    expect(find.byTooltip('待办区占满面板'), findsOneWidget);
  });

  testWidgets('collapsing caps a remembered high height at fifty percent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));
    final header = find.byKey(const ValueKey('todo-header'));
    final scaffoldHeight = tester.getSize(find.byType(Scaffold)).height;
    final maxTodoHeight = scaffoldHeight - 36;
    const minTodoHeight = 40.0;
    final highHeight =
        minTodoHeight + (maxTodoHeight - minTodoHeight) * 0.9;

    await tester.drag(
      header,
      Offset(0, -(highHeight - tester.getSize(panel).height)),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(maxTodoHeight * 0.8));
    expect(find.byTooltip('待办区占满面板'), findsOneWidget);

    await tester.tap(find.byTooltip('待办区占满面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起待办区'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(panel).height,
      closeTo(maxTodoHeight * 0.5, 0.5),
    );
  });

  testWidgets('expanded todo panel stays pinned while the window grows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));
    final scaffold = find.byType(Scaffold);

    await tester.tap(find.byTooltip('待办区占满面板'));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedContainer>(panel).duration, Duration.zero);

    await tester.binding.setSurfaceSize(const Size(800, 760));
    await tester.pump();

    expect(
      tester.getTopLeft(panel).dy,
      closeTo(tester.getTopLeft(scaffold).dy + 36, 0.1),
    );
    expect(
      tester.getBottomRight(panel).dy,
      closeTo(tester.getBottomRight(scaffold).dy, 0.1),
    );
    expect(tester.widget<AnimatedContainer>(panel).duration, Duration.zero);
  });

  testWidgets('todo text jumps to source only on double-tap', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));
    final todoText = find.descendant(
      of: panel,
      matching: find.text('修复问题'),
    );
    final controller = store.controllerFor(store.selected!);

    await tester.tap(find.byTooltip('待办区占满面板'));
    await tester.pumpAndSettle();

    // Single tap: nothing happens (no jump, panel stays expanded).
    await tester.tap(todoText);
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起待办区'), findsOneWidget);
    expect(controller.selection.isCollapsed, isTrue);

    // Double tap: jump to the source span and collapse the panel.
    await tester.tap(todoText);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(todoText);
    await tester.pumpAndSettle();
    expect(find.byTooltip('待办区占满面板'), findsOneWidget);
    expect(controller.selection.isCollapsed, isFalse);
  });

  testWidgets('expanding todo panel immediately closes selection UI', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final controller = store.controllerFor(store.selected!);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('selection-format-panel'));
    await tester.tap(find.byKey(const ValueKey('font-size-combo')));
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNWidgets(5));

    final expand = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '待办区占满面板');
    expand.onPressed!();
    await tester.pump();

    expect(controller.selection.isCollapsed, isTrue);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(of: panel, matching: find.byType(AnimatedOpacity)),
          )
          .opacity,
      0,
    );
    expect(find.byTooltip('收起待办区'), findsOneWidget);
  });

  testWidgets('wrapped todo indicators align with the first text line', (
    tester,
  ) async {
    final longTodo = List.filled(
      8,
      '这是一条会在待办区内自动换行的很长待办内容',
    ).join();
    await pumpTodoApp(
      tester,
      documentJson: jsonEncode([
        {
          'insert': longTodo,
          'attributes': {'todo': 'open'},
        },
        {'insert': '\n'},
      ]),
    );
    await tester.pumpAndSettle();

    final indicator = find.byKey(const ValueKey('todo-indicator-p1-0'));
    final text = find.text(longTodo);
    expect(tester.getRect(text).height, greaterThan(20));
    expect(tester.getRect(indicator).top, closeTo(tester.getRect(text).top, 1));
  });

  testWidgets('todo indicator animates when hovered', (tester) async {
    await pumpTodoApp(tester);
    final indicator = find.byKey(const ValueKey('todo-indicator-p1-4'));
    final hoverScale = find.ancestor(
      of: indicator,
      matching: find.byType(AnimatedScale),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);

    expect(tester.widget<AnimatedScale>(hoverScale).scale, 1);
    await mouse.moveTo(tester.getCenter(indicator));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(hoverScale).scale, 1.1);

    await mouse.moveTo(const Offset(700, 300));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(hoverScale).scale, 1);
    await mouse.removePointer();
  });

  testWidgets('todo header buttons fill the row and use danger hover styling', (
    tester,
  ) async {
    await pumpTodoApp(tester);

    IconButton button(String tooltip) => tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == tooltip);

    final clear = button('清除已完成待办');
    final expand = button('待办区占满面板');
    final add = button('新建项目');
    final pin = button('取消置顶');
    final minimize = button('最小化');
    final close = button('关闭');
    final scheme = Theme.of(tester.element(find.byTooltip('关闭'))).colorScheme;

    expect(clear.style?.fixedSize?.resolve({}), const Size.square(40));
    expect(expand.style?.fixedSize?.resolve({}), const Size.square(40));
    expect(add.style?.fixedSize?.resolve({}), const Size(32, 28));
    expect(pin.style?.fixedSize?.resolve({}), const Size(32, 28));
    for (final iconButton in [
      clear,
      expand,
      minimize,
      close,
    ]) {
      final shape = iconButton.style?.shape?.resolve({});
      expect(shape, isA<RoundedRectangleBorder>());
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.all(Radius.circular(4)),
      );
    }
    for (final iconButton in [add, pin]) {
      final shape = iconButton.style?.shape?.resolve({});
      expect(shape, isA<RoundedRectangleBorder>());
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.all(Radius.circular(7)),
      );
    }
    for (final iconButton in [expand, add, pin, minimize]) {
      expect(
        iconButton.style?.backgroundColor?.resolve({WidgetState.hovered}),
        scheme.onSurface.withValues(alpha: 0.07),
      );
    }
    expect(pin.style?.foregroundColor?.resolve({}), scheme.onSurface);
    expect(add.style?.foregroundColor?.resolve({}), scheme.onSurfaceVariant);
    expect(
      clear.style?.backgroundColor?.resolve({WidgetState.hovered}),
      scheme.error.withValues(alpha: 0.12),
    );
    expect(
      clear.style?.foregroundColor?.resolve({WidgetState.hovered}),
      scheme.error,
    );
    expect(
      close.style?.backgroundColor?.resolve({WidgetState.hovered}),
      scheme.error.withValues(alpha: 0.12),
    );
    expect(
      close.style?.foregroundColor?.resolve({WidgetState.hovered}),
      scheme.error,
    );
    expect(clear.style?.animationDuration, const Duration(milliseconds: 140));
    expect(close.style?.animationDuration, const Duration(milliseconds: 140));
  });

  testWidgets('title bar follows Edge pin-tab-add ordering and alignment', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    store.addProject('项目2');
    await tester.pumpAndSettle();

    final pinButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '取消置顶');
    final pin = find.byWidget(pinButton);
    final firstTab = find.byKey(const ValueKey('project-tab-p1'));
    final lastTab = find.byKey(
      ValueKey('project-tab-${store.projects.last.id}'),
    );
    final firstTabSurface = find.descendant(
      of: firstTab,
      matching: find.byType(AnimatedContainer),
    );
    final lastTabSurface = find.descendant(
      of: lastTab,
      matching: find.byType(AnimatedContainer),
    );
    final addButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '新建项目');
    final add = find.byWidget(addButton);
    final minimize = find.byTooltip('最小化');

    final pinRect = tester.getRect(pin);
    final firstTabSurfaceRect = tester.getRect(firstTabSurface);
    final lastTabSurfaceRect = tester.getRect(lastTabSurface);
    final addRect = tester.getRect(add);
    final scaffoldRect = tester.getRect(find.byType(Scaffold));
    expect(pinRect.left - scaffoldRect.left, 4);
    expect(firstTabSurfaceRect.left - pinRect.right, 4);
    expect(pinRect.top - scaffoldRect.top, 4);
    expect(scaffoldRect.top + 36 - pinRect.bottom, 4);
    expect(addRect.left - lastTabSurfaceRect.right, 2);
    // AnimatedContainer's render box includes the tab's 4 px top margin;
    // compare the visible button edge with the decorated tab edge instead.
    expect(pinRect.top - firstTabSurfaceRect.top, 4);
    expect(addRect.top - lastTabSurfaceRect.top, 4);
    expect(pinRect.height, 28);
    expect(addRect.height, 28);
    expect(tester.getSize(minimize), const Size(40, 36));
  });

  testWidgets('vertical mouse wheel scrolls an overflowing tab strip', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    for (var index = 0; index < 10; index++) {
      store.addProject('很长的项目标签 ${index + 2}');
    }
    await tester.pumpAndSettle();

    final strip = find.byKey(const ValueKey('project-tab-strip'));
    final scrollable = find.descendant(
      of: strip,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, 0);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(strip),
        scrollDelta: const Offset(0, 120),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();

    expect(position.pixels, greaterThan(0));
  });

  testWidgets('editor todo markers use a low accent line and grey done line', (
    tester,
  ) async {
    await pumpTodoApp(tester);

    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final styleBuilder = editor.config.customStyleBuilder!;
    final openStyle = styleBuilder(
      Attribute(kTodoAttributeKey, AttributeScope.inline, 'open'),
    );
    final doneStyle = styleBuilder(
      Attribute(kTodoAttributeKey, AttributeScope.inline, 'done'),
    );
    final scheme = Theme.of(
      tester.element(find.byType(QuillEditor)),
    ).colorScheme;

    expect(openStyle.decoration, TextDecoration.underline);
    expect(openStyle.decorationColor, scheme.primary);
    expect(openStyle.decorationThickness, 0.6);
    expect(doneStyle.decoration, TextDecoration.lineThrough);
    expect(doneStyle.decorationColor, scheme.onSurfaceVariant);
    expect(doneStyle.color, scheme.onSurfaceVariant);
  });

  testWidgets('editor caret is neutral while selection keeps project accent', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    store.setProjectColor(store.selected!, 0xFF34C759);
    await tester.pumpAndSettle();

    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final selectionTheme = editor.config.textSelectionThemeData!;
    final scheme = Theme.of(
      tester.element(find.byType(QuillEditor)),
    ).colorScheme;

    expect(selectionTheme.cursorColor, scheme.onSurface);
    expect(
      selectionTheme.selectionColor,
      scheme.primary.withValues(alpha: 0.32),
    );
    expect(selectionTheme.selectionHandleColor, const Color(0xFF34C759));
  });

  testWidgets('todo header gives visual feedback on hover', (tester) async {
    await pumpTodoApp(tester);
    final header = find.byKey(const ValueKey('todo-header'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(header));
    await tester.pump(const Duration(milliseconds: 120));

    final container = tester.widget<AnimatedContainer>(header);
    final decoration = container.decoration! as BoxDecoration;
    final scheme = Theme.of(tester.element(header)).colorScheme;
    expect(decoration.color, scheme.onSurface.withValues(alpha: 0.06));
    await mouse.removePointer();
  });

  testWidgets('default project blue is stable after choosing another accent', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    store.setProjectColor(store.selected!, 0xFFFF3B30);
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('project-tab-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题色'));
    await tester.pumpAndSettle();

    final defaultSwatch = tester.widget<Container>(
      find.byKey(const ValueKey('project-color-0')),
    );
    final decoration = defaultSwatch.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xFF007AFF));
  });

  testWidgets('every project tab shows its own theme color dot', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    store.addProject('绿色项目');
    final greenProject = store.projects.last;
    store.setProjectColor(greenProject, 0xFF34C759);
    await tester.pumpAndSettle();

    final defaultDot = tester.widget<Icon>(
      find.byKey(const ValueKey('project-color-dot-p1')),
    );
    final greenDot = tester.widget<Icon>(
      find.byKey(ValueKey('project-color-dot-${greenProject.id}')),
    );
    expect(defaultDot.color, const Color(0xFF007AFF));
    expect(greenDot.color, const Color(0xFF34C759));
  });

  testWidgets('all todos keep the accent of their owning project', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final greenProject = store.projects.first;
    store.setProjectColor(greenProject, 0xFF34C759);
    store.addProject('默认蓝项目');
    final blueProject = store.projects.last;
    blueProject.docJson = jsonEncode([
      {
        'insert': '蓝色待办',
        'attributes': {'todo': 'open'},
      },
      {'insert': '\n'},
    ]);
    store.selectProject(0);
    await tester.pumpAndSettle();

    // Single scope button: labelled with the current scope, tap to flip.
    await tester.tap(find.byTooltip('汇总全部项目'));
    await tester.pumpAndSettle();

    final scopeButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '只看当前项目');
    final scheme = Theme.of(
      tester.element(find.byTooltip('只看当前项目')),
    ).colorScheme;
    expect(scopeButton.style?.foregroundColor?.resolve({}), scheme.onSurface);

    final greenIndicator = tester.widget<Icon>(
      find.byKey(const ValueKey('todo-indicator-p1-4')),
    );
    final blueIndicator = tester.widget<Icon>(
      find.byKey(ValueKey('todo-indicator-${blueProject.id}-0')),
    );
    expect(greenIndicator.color, const Color(0xFF34C759));
    expect(blueIndicator.color, const Color(0xFF007AFF));
  });

  testWidgets('top bar keeps a balanced pin inset and flush close edge', (
    tester,
  ) async {
    await pumpTodoApp(tester);
    final pinButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '取消置顶');
    final closeButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '关闭');
    final pin = find.byWidget(pinButton);
    final close = find.byWidget(closeButton);
    final scaffold = find.byType(Scaffold);

    expect(tester.getTopLeft(pin).dx - tester.getTopLeft(scaffold).dx, 4);
    expect(tester.getBottomRight(close).dx, tester.getBottomRight(scaffold).dx);
  });

  testWidgets('todo list keeps compact spacing below its header', (
    tester,
  ) async {
    await pumpTodoApp(tester);
    final panel = find.byKey(const ValueKey('todo-panel'));
    final list = tester.widget<ListView>(
      find.descendant(of: panel, matching: find.byType(ListView)),
    );
    expect(list.padding, const EdgeInsets.fromLTRB(12, 0, 12, 8));
  });

  testWidgets('Windows editor context menu is localized and compact', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late AppStore store;
    try {
      store = await pumpTodoApp(tester);
    } finally {
      // Foundation invariants are verified before addTearDown callbacks.
      debugDefaultTargetPlatformOverride = null;
    }
    final project = store.selected!;
    store
        .controllerFor(project)
        .updateSelection(
          const TextSelection(baseOffset: 0, extentOffset: 2),
          ChangeSource.local,
        );
    await tester.pump();

    // A synthetic secondary click does not create Flutter's native desktop
    // overlay in widget tests. Build our configured menu directly from the
    // live raw-editor state so localization and sizing remain deterministic.
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final rawState = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    final menu = editor.config.contextMenuBuilder!(rawState.context, rawState);
    expect(menu, isA<TextFieldTapRegion>());
    final toolbar =
        (menu as TextFieldTapRegion).child as DesktopTextSelectionToolbar;
    final labels = <String>[];
    for (final child in toolbar.children) {
      final box = child as SizedBox;
      expect(box.height, 32);
      final button = box.child! as TextButton;
      labels.add((button.child! as Text).data!);
    }
    expect(labels, containsAll(['剪切', '复制', '粘贴', '全选']));
  });

  testWidgets('selection formatting uses font-size and color dropdowns', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final controller = store.controllerFor(store.selected!);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('font-size-combo')), findsOneWidget);
    expect(find.byKey(const ValueKey('text-color-combo')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('background-color-combo')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('font-size-combo')));
    await tester.pumpAndSettle();
    // No explicit size attribute shows the 14px base size, not a "默认".
    expect(find.text('14'), findsNWidgets(2));
    expect(find.byType(MenuItemButton), findsNWidgets(5));
    expect(find.text('13'), findsOneWidget);
    expect(find.text('18'), findsOneWidget);
    await tester.tap(find.text('18'));
    await tester.pumpAndSettle();
    expect(controller.getSelectionStyle().attributes['size']?.value, '18');

    await tester.tap(find.byKey(const ValueKey('text-color-combo')));
    await tester.pumpAndSettle();
    expect(find.text('默认文字'), findsOneWidget);
    expect(find.text('红色'), findsOneWidget);
    await tester.tap(find.text('红色'));
    await tester.pumpAndSettle();
    expect(
      controller.getSelectionStyle().attributes['color']?.value,
      '#FF3B30',
    );

    await tester.tap(find.byKey(const ValueKey('background-color-combo')));
    await tester.pumpAndSettle();
    expect(find.text('无背景'), findsOneWidget);
    expect(find.text('黄色'), findsOneWidget);
    await tester.tap(find.text('黄色'));
    await tester.pumpAndSettle();
    expect(
      controller.getSelectionStyle().attributes['background']?.value,
      'rgba(255,213,79,0.55)',
    );
  });

  testWidgets(
    'font-size menu owns only one menu and paints its selected label',
    (tester) async {
      final store = await pumpTodoApp(tester);
      final controller = store.controllerFor(store.selected!);
      controller.formatText(0, 2, Attribute.clone(Attribute.size, '22'));
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 2),
        ChangeSource.local,
      );
      await tester.pumpAndSettle();

      final combo = find.byKey(const ValueKey('font-size-combo'));
      for (var i = 0; i < 3; i++) {
        await tester.tap(combo);
        await tester.pump();
        expect(find.byType(MenuItemButton), findsNWidgets(5));
        expect(find.text('22'), findsNWidgets(2));

        final selectedLabel = find.descendant(
          of: find.byType(MenuItemButton).last,
          matching: find.text('22'),
        );
        expect(selectedLabel, findsOneWidget);
        expect(
          tester.getRect(selectedLabel).right,
          lessThan(tester.getRect(find.byType(MenuItemButton).last).right),
        );

        await tester.tap(combo);
        await tester.pump();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.text('22'), findsOneWidget);
      }
    },
  );

  testWidgets('selection panel avoids selected text and follows pointer x', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final controller = store.controllerFor(store.selected!);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('selection-format-panel'));
    expect(panel, findsOneWidget);

    final editor = find.byType(QuillEditor);
    final renderEditor = tester
        .state<QuillRawEditorState>(find.byType(QuillRawEditor))
        .renderEditor;
    Rect selectionRectFor(int start, int end) {
      final startRect = renderEditor.getLocalRectForCaret(
        TextPosition(offset: start),
      );
      final endRect = renderEditor.getLocalRectForCaret(
        TextPosition(offset: end, affinity: TextAffinity.upstream),
      );
      return Rect.fromPoints(
        renderEditor.localToGlobal(
          Offset(
            startRect.left < endRect.left ? startRect.left : endRect.left,
            startRect.top < endRect.top ? startRect.top : endRect.top,
          ),
        ),
        renderEditor.localToGlobal(
          Offset(
            startRect.right > endRect.right ? startRect.right : endRect.right,
            startRect.bottom > endRect.bottom
                ? startRect.bottom
                : endRect.bottom,
          ),
        ),
      );
    }

    final selectionRect = selectionRectFor(0, 2);
    expect(tester.getRect(panel).overlaps(selectionRect.inflate(9)), isFalse);

    // While the pointer is down the panel hides...
    final listener = tester.widget<Listener>(
      find.byKey(const ValueKey('editor-pointer-listener-p1')),
    );
    await tester.tap(find.byKey(const ValueKey('font-size-combo')));
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNWidgets(5));
    listener.onPointerDown!(const PointerDownEvent(position: Offset(50, 40)));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    final opacityHidden = tester.widget<AnimatedOpacity>(
      find.ancestor(of: panel, matching: find.byType(AnimatedOpacity)),
    );
    expect(opacityHidden.opacity, 0);

    // ...and on release it uses the pointer only as a horizontal preference.
    listener.onPointerUp!(const PointerUpEvent(position: Offset(320, 80)));
    await tester.pump();
    final panelRect = tester.getRect(panel);
    expect(panelRect.overlaps(selectionRect.inflate(9)), isFalse);
    expect(panelRect.center.dx - tester.getTopLeft(editor).dx, closeTo(320, 1));

    // A later line has enough space above, so keyboard selection uses the
    // preferred upper candidate instead of the old bottom-left fallback.
    controller.replaceText(8, 0, '\n第三行\n第四行', null);
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 13, extentOffset: 15),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    final laterSelectionRect = selectionRectFor(13, 15);
    expect(
      tester.getRect(panel).bottom,
      lessThanOrEqualTo(laterSelectionRect.top - 9),
    );
  });

  testWidgets('editor uses a stable Simplified Chinese glyph fallback', (
    tester,
  ) async {
    await pumpTodoApp(tester);

    final style = tester.widget<DefaultTextStyle>(
      find.byKey(const ValueKey('editor-text-style-p1')),
    );
    expect(style.style.locale, const Locale('zh', 'CN'));
    expect(style.style.fontFamilyFallback, contains('Microsoft YaHei UI'));
    expect(style.style.fontFamilyFallback, contains('PingFang SC'));
  });

  testWidgets('22px inline text produces a matching caret prototype', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final controller = store.controllerFor(store.selected!);
    // The second line starts at 4 and has four visible characters followed by
    // a newline. A caret at offset 8 must inherit the last visible glyph, not
    // the newline's base paragraph style.
    controller.formatText(4, 4, Attribute.clone(Attribute.size, '22'));
    controller.updateSelection(
      const TextSelection.collapsed(offset: 8),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();

    final lines = find
        .byType(EditableTextLine)
        .evaluate()
        .map((element) => element.renderObject! as RenderEditableTextLine);
    final line = lines.firstWhere(
      (candidate) =>
          candidate.line.documentOffset <= 8 &&
          8 < candidate.line.documentOffset + candidate.line.length,
    );
    final position = TextPosition(offset: 8 - line.line.documentOffset);
    final preferred = line.preferredLineHeight(position);
    expect(preferred, greaterThan(20));
    expect(
      line.getCaretPrototype(position).height,
      closeTo(preferred - 4, 0.01),
    );
  });

  testWidgets('editor config keeps the reliable desktop paste path', (
    tester,
  ) async {
    final store = await pumpTodoApp(tester);
    final controller = store.controllerFor(store.selected!);
    expect(
      // ignore: experimental_member_use
      controller.config.clipboardConfig?.enableExternalRichPaste,
      isFalse,
    );

    // Widget tests do not have a real Windows clipboard service. Verify the
    // accelerator wiring here; Quill owns the platform clipboard operation.
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final hasPasteShortcut = editor.config.customShortcuts!.entries.any((
      entry,
    ) {
      final activator = entry.key;
      return activator is SingleActivator &&
          activator.trigger == LogicalKeyboardKey.keyV &&
          activator.control &&
          !activator.meta &&
          entry.value is PasteTextIntent;
    });
    expect(hasPasteShortcut, isTrue);
  });

  testWidgets('Ctrl+Enter marks selected body lines as todos', (tester) async {
    final document = jsonEncode([
      {'insert': '标题'},
      {
        'insert': '\n',
        'attributes': {'header': 2},
      },
      {'insert': '第一项\n第二项\n'},
    ]);
    final store = await pumpTodoApp(tester, documentJson: document);
    final controller = store.controllerFor(store.selected!);
    controller.updateSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: controller.document.length - 1,
      ),
      ChangeSource.local,
    );
    await tester.pump();

    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final shortcut = editor.config.customShortcuts!.entries.singleWhere((
      entry,
    ) {
      final activator = entry.key;
      return activator is SingleActivator &&
          activator.trigger == LogicalKeyboardKey.enter &&
          activator.control &&
          !activator.meta;
    });
    expect(
      editor.config.customActions,
      contains(shortcut.value.runtimeType),
    );
    final editorLine = find.byType(EditableTextLine).first;
    Actions.invoke(tester.element(editorLine), shortcut.value);
    await tester.pump();

    final spans = parseTodoSpans(controller.document.toDelta().toJson());
    expect(spans.map((span) => span.text), ['第一项', '第二项']);
  });

  testWidgets('editing ordinary text keeps later todo row identities', (
    tester,
  ) async {
    final document = jsonEncode([
      {
        'insert': '待办1',
        'attributes': {'todo': 'open'},
      },
      {'insert': '\n普通行\n'},
      {
        'insert': '待办2',
        'attributes': {'todo': 'open'},
      },
      {'insert': '\n'},
      {
        'insert': '待办3',
        'attributes': {'todo': 'open'},
      },
      {'insert': '\n'},
    ]);
    final store = await pumpTodoApp(tester, documentJson: document);
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('todo-panel'));

    Finder todoTile(String text) => find.ancestor(
      of: find.descendant(of: panel, matching: find.text(text)),
      matching: find.byType(TweenAnimationBuilder<double>),
    );

    final secondElement = todoTile('待办2').evaluate().single;
    final thirdElement = todoTile('待办3').evaluate().single;
    final controller = store.controllerFor(store.selected!);
    final insertAt = '待办1\n普通'.length;
    controller.replaceText(
      insertAt,
      0,
      '新',
      TextSelection.collapsed(offset: insertAt + 1),
    );
    await tester.pump(const Duration(milliseconds: 30));

    expect(todoTile('待办2').evaluate().single, same(secondElement));
    expect(todoTile('待办3').evaluate().single, same(thirdElement));
  });

  testWidgets('close button asks for confirmation', (tester) async {
    await pumpTodoApp(tester);

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      kAppDisplayName,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('关闭$kAppDisplayName'), findsOneWidget);
    expect(find.text('确定要关闭吗？所有内容都已自动保存。'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('关闭$kAppDisplayName'), findsNothing);
  });

  testWidgets('Windows tray close offers and remembers hide or exit', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final trayCalls = <MethodCall>[];
    final windowCalls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('tray_manager'), (
      call,
    ) async {
      trayCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      windowCalls.add(call.method);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('tray_manager'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });

    final store = await pumpTodoApp(tester, enableSystemTray: true);
    await tester.pumpAndSettle();
    expect(
      trayCalls.map((call) => call.method),
      containsAll(['setIcon', 'setToolTip', 'setContextMenu']),
    );
    expect(
      trayCalls
          .singleWhere((call) => call.method == 'setIcon')
          .arguments
          .toString(),
      contains('tray_icon.ico'),
    );
    expect(
      trayCalls
          .singleWhere((call) => call.method == 'setToolTip')
          .arguments
          .toString(),
      contains(kAppDisplayName),
    );

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('关闭窗口时要怎么处理？'), findsOneWidget);
    expect(find.text('隐藏到系统托盘'), findsOneWidget);
    expect(find.text('退出应用'), findsOneWidget);
    expect(find.text('记住选择，下次不再提示'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('隐藏到系统托盘'));
    await tester.pumpAndSettle();
    expect(windowCalls, contains('hide'));
    expect(windowCalls, isNot(contains('close')));
    expect(store.closePreference, ClosePreference.hideToTray);

    windowCalls.clear();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('关闭窗口时要怎么处理？'), findsNothing);
    expect(windowCalls, contains('hide'));

    await store.setClosePreference(ClosePreference.ask);
    windowCalls.clear();
    trayCalls.clear();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('退出应用'));
    await tester.pumpAndSettle();
    expect(
      windowCalls,
      containsAllInOrder(['hide', 'setPreventClose', 'close']),
    );
    expect(windowCalls, isNot(contains('destroy')));
    expect(trayCalls.map((call) => call.method), contains('destroy'));
    expect(store.closePreference, ClosePreference.exitApplication);
  });
}
