import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sticky_panel/models.dart';

void main() {
  test('entry json round-trip preserves fields', () {
    final entry = Entry(
      id: 'a1',
      text: '跟进合同',
      isTodo: true,
      done: true,
      bold: true,
      highlight: 0x66FFD54F,
      fontSize: 18,
    );
    final restored = Entry.fromJson(jsonDecode(jsonEncode(entry.toJson())));
    expect(restored.id, entry.id);
    expect(restored.text, entry.text);
    expect(restored.isTodo, isTrue);
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
}
