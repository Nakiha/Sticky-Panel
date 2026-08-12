import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sticky_panel/models.dart';
import 'package:sticky_panel/store.dart';

void main() {
  test('entry json round-trip preserves fields', () {
    final entry = Entry(
      id: 'a1',
      text: '跟进合同',
      isTodo: true,
      isHeading: true,
      done: true,
      bold: true,
      highlight: 0x66FFD54F,
      fontSize: 18,
    );
    final restored = Entry.fromJson(jsonDecode(jsonEncode(entry.toJson())));
    expect(restored.id, entry.id);
    expect(restored.text, entry.text);
    expect(restored.isTodo, isTrue);
    expect(restored.isHeading, isTrue);
    expect(restored.done, isTrue);
    expect(restored.bold, isTrue);
    expect(restored.highlight, 0x66FFD54F);
    expect(restored.fontSize, 18);
  });

  test('project json round-trip preserves entries', () {
    final project = Project(id: 'p1', name: '项目A', entries: [
      Entry(id: 'a', text: '备忘'),
      Entry(id: 'b', text: '待办', isTodo: true),
    ]);
    final restored = Project.fromJson(jsonDecode(jsonEncode(project.toJson())));
    expect(restored.name, '项目A');
    expect(restored.entries.length, 2);
    expect(restored.entries[1].isTodo, isTrue);
  });

  test('insertEntryAfter inserts right below the given line', () {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    final project = Project(id: 'p', name: 'P', entries: [
      Entry(id: 'a', text: '一'),
      Entry(id: 'b', text: '二'),
    ]);
    store.projects.add(project);

    final inserted = store.insertEntryAfter(project, project.entries.first);
    expect(project.entries.map((e) => e.id), ['a', inserted.id, 'b']);

    final atStart = store.insertEntryAfter(project, null);
    expect(project.entries.first.id, atStart.id);
  });

  test('sectionNameFor returns the nearest heading above', () {
    final heading = Entry(id: 'h', text: '客户端', isHeading: true);
    final todo = Entry(id: 't', text: '修崩溃', isTodo: true);
    final project = Project(id: 'p', name: 'P', entries: [
      Entry(id: 'n', text: '散记'),
      heading,
      todo,
    ]);
    expect(AppStore.sectionNameFor(project, todo), '客户端');
    expect(AppStore.sectionNameFor(project, heading), isNull);
  });
}
