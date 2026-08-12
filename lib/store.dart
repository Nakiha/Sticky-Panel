import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'todos.dart';

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
      );
      controller.addListener(() => _onDocumentChanged(project, controller));
      return controller;
    });
  }

  /// Inline attributes (todo/underline/strike) must never sit on a newline
  /// character: Quill treats the trailing `\n` as the line's format carrier,
  /// so an underline there bleeds into everything typed afterwards. Split
  /// ops so newline-only parts are stripped of inline attributes (line
  /// attributes like `header`/`list` are kept).
  static List<dynamic> _sanitizeOps(List<dynamic> ops) {
    const inlineKeys = [kTodoAttributeKey, 'underline', 'strike'];
    final cleaned = <dynamic>[];
    for (final op in ops) {
      if (op is! Map) {
        cleaned.add(op);
        continue;
      }
      final data = op['insert'];
      final attributes = (op['attributes'] as Map?)?.cast<String, dynamic>();
      if (data is! String ||
          attributes == null ||
          !attributes.keys.any(inlineKeys.contains) ||
          !data.contains('\n')) {
        cleaned.add(op);
        continue;
      }
      final lineAttributes = Map<String, dynamic>.from(attributes)
        ..removeWhere((key, _) => inlineKeys.contains(key));
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

  void _onDocumentChanged(Project project, QuillController controller) {
    final docJson = jsonEncode(controller.document.toDelta().toJson());
    // Selection-only changes notify too; skip those to avoid churn.
    if (docJson == project.docJson) return;
    project.docJson = docJson;
    notifyListeners();
    _save();
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

  /// Mark the selected range as a todo: todo attribute + underline, so the
  /// linked text stays visible in the document.
  void markTodoSpan(Project project, int start, int length) {
    final controller = controllerFor(project);
    _formatInlineSkippingNewlines(
        controller, start, length, todoAttribute('open'));
    _formatInlineSkippingNewlines(
        controller, start, length, Attribute.underline);
  }

  /// Remove the todo marking (and its underline/strike) from a range,
  /// keeping the text itself. Unlike marking, removal also targets newline
  /// characters, so legacy pollution gets cleaned up too.
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
    _formatInlineSkippingNewlines(
      controller,
      span.start,
      span.length,
      span.done
          ? Attribute.clone(Attribute.strikeThrough, null)
          : Attribute.strikeThrough,
    );
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
