import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'todos.dart';

typedef _PendingTodoFormat = ({int index, int length, String state});

/// Central state holder: projects, selection, quill controllers, persistence.
class AppStore extends ChangeNotifier {
  static const _storageKey = 'sticky_panel_data_v2';
  static const _legacyStorageKey = 'sticky_panel_data_v1';

  final List<Project> projects = [];
  int selectedIndex = 0;

  /// One controller per project, created lazily and kept so undo history
  /// and selection survive project switches.
  final _controllers = <String, QuillController>{};

  Project? get selected => projects.isEmpty
      ? null
      : projects[selectedIndex.clamp(0, projects.length - 1)];

  /// The live controller for [project]'s document.
  ///
  /// Document changes are mirrored back into [Project.docJson], persisted,
  /// and broadcast so the todo section stays in sync in real time.
  QuillController controllerFor(Project project) {
    return _controllers.putIfAbsent(project.id, () {
      Document document;
      try {
        document = project.docJson.isEmpty
            ? Document()
            : Document.fromJson(_sanitizeOps(
                jsonDecode(project.docJson) as List<dynamic>));
      } catch (_) {
        document = Document();
      }
      final controller = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
        // The native rich-clipboard probe in flutter_quill 11.x can stop the
        // paste pipeline before it reaches Flutter's plain-text clipboard on
        // Windows. Notes in Sticky Panel are text-first, so skip that fragile
        // probe and paste through the reliable system text format directly.
        config: const QuillControllerConfig(
          // ignore: experimental_member_use
          clipboardConfig: QuillClipboardConfig(
            // ignore: experimental_member_use
            enableExternalRichPaste: false,
          ),
        ),
      );
      _PendingTodoFormat? pendingTodoFormat;
      controller.onReplaceText = (index, len, data) {
        pendingTodoFormat =
            _todoFormatForReplacement(controller.document, index, len, data);
        return true;
      };
      controller.addListener(() {
        final pending = pendingTodoFormat;
        pendingTodoFormat = null;
        if (pending != null) {
          controller.document.format(
            pending.index,
            pending.length,
            todoAttribute(pending.state),
          );
        }
        _onDocumentChanged(project, controller);
      });
      return controller;
    });
  }

  /// Quill's built-in insertion rules do not know about our custom `todo`
  /// inline attribute. Text typed in the middle of a todo would therefore be
  /// inserted without that attribute and split one logical todo into two.
  ///
  /// Inherit the state only when the replacement is unambiguously inside one
  /// todo. Requiring matching attributes on both sides of a collapsed cursor
  /// deliberately avoids merging two independently marked todos.
  static _PendingTodoFormat? _todoFormatForReplacement(
    Document document,
    int index,
    int len,
    Object? data,
  ) {
    if (data is! String || data.isEmpty || data.contains('\n')) return null;

    String? todoState;
    if (len > 0) {
      if (index < 0 || index + len > document.length) return null;
      final replacedText = document.getPlainText(index, len);
      if (replacedText.contains('\n')) return null;
      todoState = _todoStateFromStyle(document.collectStyle(index, len));
    } else {
      final left = _todoStateAt(document, index - 1);
      final right = _todoStateAt(document, index);
      if (left != null && left == right) todoState = left;
    }

    if (todoState == null) return null;
    return (index: index, length: data.length, state: todoState);
  }

  static String? _todoStateAt(Document document, int offset) {
    if (offset < 0 || offset >= document.length) return null;
    if (document.getPlainText(offset, 1) == '\n') return null;
    return _todoStateFromStyle(document.collectStyle(offset, 1));
  }

  static String? _todoStateFromStyle(Style style) {
    final value = style.attributes[kTodoAttributeKey]?.value;
    return value == 'open' || value == 'done' ? value as String : null;
  }

  /// Inline attributes must never sit on a newline character: Quill carries
  /// line format on the trailing `\n`, so an attribute there leaks into
  /// everything typed afterwards. Legacy `underline`/`strike` attributes
  /// (no longer stored; the todo underline is derived at render time) are
  /// stripped everywhere, and the todo attribute is stripped from newlines.
  static List<dynamic> _sanitizeOps(List<dynamic> ops) {
    final cleaned = <dynamic>[];
    for (final op in ops) {
      if (op is! Map) {
        cleaned.add(op);
        continue;
      }
      final data = op['insert'];
      var attributes = (op['attributes'] as Map?)?.cast<String, dynamic>();
      if (data is! String || attributes == null) {
        cleaned.add(op);
        continue;
      }
      // underline/strike are never stored anymore — drop them outright.
      attributes = Map<String, dynamic>.from(attributes)
        ..remove('underline')
        ..remove('strike');
      if (attributes.isEmpty) attributes = null;
      if (attributes == null ||
          !attributes.containsKey(kTodoAttributeKey) ||
          !data.contains('\n')) {
        cleaned.add({
          'insert': data,
          'attributes': ?attributes,
        });
        continue;
      }
      final lineAttributes = Map<String, dynamic>.from(attributes)
        ..remove(kTodoAttributeKey);
      final parts = data.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) {
          cleaned.add({'insert': parts[i], 'attributes': attributes});
        }
        if (i < parts.length - 1) {
          cleaned.add({
            'insert': '\n',
            if (lineAttributes.isNotEmpty) 'attributes': lineAttributes,
          });
        }
      }
    }
    return cleaned;
  }

  bool _sanitizing = false;

  void _onDocumentChanged(Project project, QuillController controller) {
    if (_sanitizing) return;
    // Pressing Enter at the end of a todo span copies the todo attribute
    // onto the new newline, and the next line then inherits it. Strip the
    // todo attribute from newline characters on every change.
    _stripTodoFromNewlines(controller);
    final docJson = jsonEncode(controller.document.toDelta().toJson());
    // Selection-only changes notify too; skip those to avoid churn.
    if (docJson == project.docJson) return;
    project.docJson = docJson;
    notifyListeners();
    _save();
  }

  void _stripTodoFromNewlines(QuillController controller) {
    final ops = controller.document.toDelta().toJson();
    final positions = <int>[];
    var offset = 0;
    for (final op in ops) {
      final data = op['insert'];
      if (data is! String) {
        if (data != null) offset += 1;
        continue;
      }
      final attributes = op['attributes']?.cast<String, dynamic>();
      if (attributes != null && attributes.containsKey(kTodoAttributeKey)) {
        for (var i = 0; i < data.length; i++) {
          if (data[i] == '\n') positions.add(offset + i);
        }
      }
      offset += data.length;
    }
    if (positions.isEmpty) return;
    _sanitizing = true;
    try {
      for (final pos in positions.reversed) {
        controller.formatText(
            pos, 1, Attribute.clone(todoAttribute('open'), null));
      }
    } finally {
      _sanitizing = false;
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        projects
          ..clear()
          ..addAll((json['projects'] as List<dynamic>? ?? [])
              .map((e) => Project.fromJson(e as Map<String, dynamic>)));
        selectedIndex = (json['selectedIndex'] as num?)
                ?.toInt()
                .clamp(0, projects.isEmpty ? 0 : projects.length - 1) ??
            0;
      } catch (_) {
        // Corrupted data: start fresh rather than crash.
        projects.clear();
        selectedIndex = 0;
      }
    } else {
      _migrateLegacy(prefs.getString(_legacyStorageKey));
    }
    if (projects.isEmpty) {
      projects.add(Project(id: _newId(), name: '默认项目'));
    }
    notifyListeners();
  }

  /// One-shot migration from the v1 line-based model: each entry becomes one
  /// line in the project's quill document, keeping heading/todo/done state.
  void _migrateLegacy(String? raw) {
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final legacyProjects = json['projects'] as List<dynamic>? ?? [];
      for (final p in legacyProjects) {
        final map = p as Map<String, dynamic>;
        final entries = map['entries'] as List<dynamic>? ?? [];
        final ops = <Map<String, dynamic>>[
          for (final e in entries)
            () {
              final entry = e as Map<String, dynamic>;
              final attributes = <String, dynamic>{
                if (entry['isHeading'] == true) 'header': 2,
                if (entry['isTodo'] == true)
                  'list': entry['done'] == true ? 'checked' : 'unchecked',
              };
              return <String, dynamic>{
                'insert': '${entry['text'] as String? ?? ''}\n',
                if (attributes.isNotEmpty) 'attributes': attributes,
              };
            }(),
        ];
        if (ops.isEmpty) ops.add(const {'insert': '\n'});
        projects.add(Project(
          id: map['id'] as String? ?? _newId(),
          name: map['name'] as String? ?? '未命名项目',
          docJson: jsonEncode(ops),
        ));
      }
      selectedIndex =
          (json['selectedIndex'] as num?)?.toInt().clamp(0, projects.isEmpty ? 0 : projects.length - 1) ??
              0;
      _save();
    } catch (_) {
      // Unreadable legacy data: ignore and start fresh.
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode({
        'selectedIndex': selectedIndex,
        'projects': projects.map((e) => e.toJson()).toList(),
      }),
    );
  }

  /// Save without notifying listeners.
  void persist() => _save();

  void selectProject(int index) {
    if (index < 0 || index >= projects.length) return;
    selectedIndex = index;
    notifyListeners();
    _save();
  }

  void addProject(String name) {
    projects.add(
        Project(id: _newId(), name: name.trim().isEmpty ? '新项目' : name.trim()));
    selectedIndex = projects.length - 1;
    notifyListeners();
    _save();
  }

  void renameProject(Project project, String name) {
    if (name.trim().isEmpty) return;
    project.name = name.trim();
    notifyListeners();
    _save();
  }

  void setProjectColor(Project project, int colorValue) {
    project.colorValue = colorValue;
    notifyListeners();
    _save();
  }

  void deleteProject(Project project) {
    projects.remove(project);
    _controllers.remove(project.id)?.dispose();
    if (projects.isEmpty) {
      projects.add(Project(id: _newId(), name: '默认项目'));
    }
    selectedIndex = selectedIndex.clamp(0, projects.length - 1);
    notifyListeners();
    _save();
  }

  /// Custom inline attribute marking a text span as a todo ('open'/'done').
  static Attribute<String?> todoAttribute(String value) =>
      Attribute(kTodoAttributeKey, AttributeScope.inline, value);

  /// Apply [attribute] to [start, start+length) one line segment at a time,
  /// never touching newline characters (attributes on `\n` leak into text
  /// typed afterwards).
  static void _formatInlineSkippingNewlines(
      QuillController controller, int start, int length, Attribute attribute) {
    final plain = controller.document.toPlainText();
    final end = start + length;
    var i = start;
    while (i < end) {
      var j = plain.indexOf('\n', i);
      if (j < 0 || j > end) j = end;
      if (j > i) controller.formatText(i, j - i, attribute);
      i = j + 1;
    }
  }

  /// Mark the selected range as a todo. The underline is NOT stored — it is
  /// derived from the todo attribute at render time (customStyleBuilder),
  /// so there is no real underline attribute that could leak.
  void markTodoSpan(Project project, int start, int length) {
    final controller = controllerFor(project);
    _formatInlineSkippingNewlines(
        controller, start, length, todoAttribute('open'));
  }

  /// Remove the todo marking from a range, keeping the text itself. Also
  /// strips legacy stored underline/strike attributes.
  void unmarkTodoSpan(Project project, int start, int length) {
    final controller = controllerFor(project);
    controller.formatText(
        start, length, Attribute.clone(todoAttribute('open'), null));
    controller.formatText(
        start, length, Attribute.clone(Attribute.underline, null));
    controller.formatText(
        start, length, Attribute.clone(Attribute.strikeThrough, null));
  }

  /// Flip a todo span between done and open.
  void toggleSpanDone(Project project, TodoSpan span) {
    final controller = controllerFor(project);
    _formatInlineSkippingNewlines(controller, span.start, span.length,
        todoAttribute(span.done ? 'open' : 'done'));
  }

  /// Unmark all completed todo spans in a project (the text stays on the
  /// board, only the todo flag and its underline are removed).
  void clearDone(Project project) {
    final controller = controllerFor(project);
    final spans = parseTodoSpans(controller.document.toDelta().toJson());
    for (final span in spans.where((s) => s.done).toList().reversed) {
      unmarkTodoSpan(project, span.start, span.length);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (UniqueKey().hashCode & 0xFFFFFF).toRadixString(36);
}
