import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Central state holder: projects, selection, and persistence.
class AppStore extends ChangeNotifier {
  static const _storageKey = 'sticky_panel_data_v1';

  final List<Project> projects = [];
  int selectedIndex = 0;

  Project? get selected =>
      projects.isEmpty ? null : projects[selectedIndex.clamp(0, projects.length - 1)];

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
        selectedIndex =
            (json['selectedIndex'] as num?)?.toInt().clamp(0, projects.isEmpty ? 0 : projects.length - 1) ?? 0;
      } catch (_) {
        // Corrupted data: start fresh rather than crash.
        projects.clear();
        selectedIndex = 0;
      }
    }
    if (projects.isEmpty) {
      projects.add(Project(id: _newId(), name: '默认项目'));
    }
    notifyListeners();
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

  /// Save without notifying listeners — used while typing, where the
  /// TextField already shows the new text and a rebuild would be wasted.
  void persist() => _save();

  void selectProject(int index) {
    if (index < 0 || index >= projects.length) return;
    selectedIndex = index;
    notifyListeners();
    _save();
  }

  void addProject(String name) {
    projects.add(Project(id: _newId(), name: name.trim().isEmpty ? '新项目' : name.trim()));
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
    if (projects.isEmpty) {
      projects.add(Project(id: _newId(), name: '默认项目'));
    }
    selectedIndex = selectedIndex.clamp(0, projects.length - 1);
    notifyListeners();
    _save();
  }

  Entry addEntry(Project project, String text, {bool isTodo = false}) {
    final entry = Entry(id: _newId(), text: text, isTodo: isTodo);
    project.entries.add(entry);
    notifyListeners();
    _save();
    return entry;
  }

  /// Insert a new empty line right after [after] (or at the start if null).
  Entry insertEntryAfter(Project project, Entry? after) {
    final entry = Entry(id: _newId(), text: '');
    final index = after == null ? -1 : project.entries.indexOf(after);
    project.entries.insert(index + 1, entry);
    notifyListeners();
    _save();
    return entry;
  }

  /// The heading a line belongs to: the nearest heading above it on the
  /// board, or null when there is none.
  static String? sectionNameFor(Project project, Entry entry) {
    String? section;
    for (final e in project.entries) {
      if (e == entry) break;
      if (e.isHeading) section = e.text;
    }
    return section;
  }

  void setHeading(Entry entry, bool isHeading) {
    entry.isHeading = isHeading;
    notifyListeners();
    _save();
  }

  void updateEntryText(Entry entry, String text) {
    entry.text = text;
    notifyListeners();
    _save();
  }

  /// Flip a line between plain note and todo, keeping text and styling.
  void toggleEntryKind(Entry entry) {
    entry.isTodo = !entry.isTodo;
    if (!entry.isTodo) entry.done = false;
    notifyListeners();
    _save();
  }

  void toggleDone(Entry entry) {
    entry.done = !entry.done;
    notifyListeners();
    _save();
  }

  void toggleBold(Entry entry) {
    entry.bold = !entry.bold;
    notifyListeners();
    _save();
  }

  void setHighlight(Entry entry, int colorValue) {
    entry.highlight = colorValue;
    notifyListeners();
    _save();
  }

  void setFontSize(Entry entry, double size) {
    entry.fontSize = size;
    notifyListeners();
    _save();
  }

  void removeEntry(Project project, Entry entry) {
    project.entries.remove(entry);
    notifyListeners();
    _save();
  }

  /// [newIndex] is the insertion index after removal, as reported by
  /// `ReorderableListView.onReorderItem` (already adjusted).
  void reorderEntry(Project project, int oldIndex, int newIndex) {
    final entry = project.entries.removeAt(oldIndex);
    project.entries.insert(newIndex, entry);
    notifyListeners();
    _save();
  }

  /// Remove all completed todo lines in a project, keeping notes untouched.
  void clearDone(Project project) {
    project.entries.removeWhere((e) => e.isTodo && e.done);
    notifyListeners();
    _save();
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (UniqueKey().hashCode & 0xFFFFFF).toRadixString(36);
}
