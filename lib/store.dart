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
            : Document.fromJson(jsonDecode(project.docJson) as List<dynamic>);
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

  /// Flip a todo line between done and open.
  ///
  /// Note: Quill's line-format rule always extends the range to the next
  /// newline, so passing [DocLine.length] (without the newline) formats
  /// exactly this line; including the newline would also hit the next one.
  void toggleTodoDone(Project project, DocLine line) {
    final controller = controllerFor(project);
    controller.formatText(
      line.start,
      line.length,
      line.done ? Attribute.unchecked : Attribute.checked,
    );
  }

  /// Remove all completed todo lines in a project, keeping notes untouched.
  /// Lines are deleted from the end backwards so earlier offsets stay valid.
  void clearDone(Project project) {
    final controller = controllerFor(project);
    final lines = parseDocLines(controller.document.toDelta().toJson());
    final doneLines = lines.where((l) => l.done).toList();
    for (final line in doneLines.reversed) {
      if (line.start + line.length + 1 < controller.document.length) {
        controller.replaceText(line.start, line.length + 1, '', null);
      } else {
        // Last line of the document: the trailing newline must stay, so
        // delete only the text and strip the checkbox from the empty line.
        controller.replaceText(line.start, line.length, '', null);
        controller.formatText(line.start, 1, Attribute.clone(Attribute.list, null));
      }
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
