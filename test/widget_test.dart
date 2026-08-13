import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
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
    for (final iconButton in [clear, expand, minimize, close]) {
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

    expect(
      tester.getTopLeft(pin).dx - tester.getTopLeft(scaffold).dx,
      4,
    );
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
    expect(find.text('默认'), findsWidgets);
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

  testWidgets('selection panel wraps its controls and follows selection drag', (
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
    final listenerFinder = find.byKey(
      const ValueKey('editor-pointer-listener-p1'),
    );
    expect(
      tester.getSize(panel).width,
      lessThan(tester.getSize(listenerFinder).width - 24),
    );

    final listener = tester.widget<Listener>(listenerFinder);
    listener.onPointerUp!(const PointerUpEvent(position: Offset(100, 80)));
    await tester.pump();

    final localTop =
        tester.getTopLeft(panel).dy - tester.getTopLeft(listenerFinder).dy;
    expect(localTop, 90);
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
