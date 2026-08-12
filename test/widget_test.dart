import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sticky_panel/models.dart';
import 'package:sticky_panel/store.dart';
import 'package:sticky_panel/todos.dart';

void main() {
  group('parseDocLines', () {
    test('recognizes checked and unchecked todo lines', () {
      final lines = parseDocLines(const [
        {'insert': '普通笔记\n'},
        {
          'insert': '买牛奶\n',
          'attributes': {'list': 'unchecked'}
        },
        {
          'insert': '已办完\n',
          'attributes': {'list': 'checked'}
        },
      ]);
      expect(lines.length, 3);
      expect(lines[0].isTodo, isFalse);
      expect(lines[1].isTodo, isTrue);
      expect(lines[1].done, isFalse);
      expect(lines[2].isTodo, isTrue);
      expect(lines[2].done, isTrue);
    });

    test('tracks document offsets for each line', () {
      final lines = parseDocLines(const [
        {'insert': 'ab\ncde\n'},
      ]);
      expect(lines[0].start, 0);
      expect(lines[0].length, 2);
      expect(lines[1].start, 3);
      expect(lines[1].length, 3);
    });

    test('marks header lines', () {
      final lines = parseDocLines(const [
        {
          'insert': '工作\n',
          'attributes': {'header': 2}
        },
      ]);
      expect(lines.single.isHeader, isTrue);
      expect(lines.single.isTodo, isFalse);
    });
  });

  group('groupTodos', () {
    test('groups todos under the nearest heading above', () {
      final lines = parseDocLines(const [
        {
          'insert': '工作\n',
          'attributes': {'header': 2}
        },
        {
          'insert': '写周报\n',
          'attributes': {'list': 'unchecked'}
        },
        {
          'insert': '生活\n',
          'attributes': {'header': 1}
        },
        {
          'insert': '买牛奶\n',
          'attributes': {'list': 'checked'}
        },
      ]);
      final groups = groupTodos(lines);
      expect(groups.length, 2);
      expect(groups[0].title, '工作');
      expect(groups[0].todos.single.text, '写周报');
      expect(groups[1].title, '生活');
      expect(groups[1].todos.single.done, isTrue);
    });

    test('todos before any heading fall into 未分组', () {
      final lines = parseDocLines(const [
        {
          'insert': '杂事\n',
          'attributes': {'list': 'unchecked'}
        },
        {
          'insert': '段落\n',
          'attributes': {'header': 2}
        },
        {
          'insert': '段落事项\n',
          'attributes': {'list': 'unchecked'}
        },
      ]);
      final groups = groupTodos(lines);
      expect(groups[0].title, kUngroupedTitle);
      expect(groups[0].todos.single.text, '杂事');
      expect(groups[1].title, '段落');
    });

    test('ignores empty todo lines', () {
      final lines = parseDocLines(const [
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'}
        },
      ]);
      expect(groupTodos(lines), isEmpty);
    });
  });

  group('models', () {
    test('project json round-trip preserves docJson', () {
      final project = Project(
        id: 'p1',
        name: '项目A',
        docJson: jsonEncode(const [
          {
            'insert': '买牛奶\n',
            'attributes': {'list': 'unchecked'}
          },
        ]),
      );
      final restored =
          Project.fromJson(jsonDecode(jsonEncode(project.toJson())));
      expect(restored.id, 'p1');
      expect(restored.name, '项目A');
      expect(restored.docJson, project.docJson);
    });

    test('project defaults to an empty document', () {
      final restored = Project.fromJson(const {'id': 'p2', 'name': 'B'});
      expect(restored.docJson, '');
    });
  });

  group('AppStore', () {
    test('persists and reloads projects with documents', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      store.addProject('工作');
      final project = store.selected!;
      final controller = store.controllerFor(project);
      controller.replaceText(0, 0, '买牛奶', null);
      await Future<void>.delayed(Duration.zero);

      final reloaded = AppStore();
      await reloaded.load();
      expect(reloaded.projects.length, 2);
      expect(reloaded.selected!.name, '工作');
      expect(
        reloaded.controllerFor(reloaded.selected!).document.toPlainText(),
        contains('买牛奶'),
      );
    });

    test('migrates v1 line-based data into a quill document', () async {
      SharedPreferences.setMockInitialValues({
        'sticky_panel_data_v1': jsonEncode({
          'selectedIndex': 0,
          'projects': [
            {
              'id': 'p1',
              'name': '旧项目',
              'entries': [
                {'id': 'a', 'text': '段落标题', 'isHeading': true},
                {'id': 'b', 'text': '旧待办', 'isTodo': true, 'done': true},
                {'id': 'c', 'text': '普通行'},
              ],
            },
          ],
        }),
      });
      final store = AppStore();
      await store.load();
      expect(store.projects.single.name, '旧项目');
      final lines = parseDocLines(
          store.controllerFor(store.projects.single).document.toDelta().toJson());
      expect(lines[0].text, '段落标题');
      expect(lines[0].isHeader, isTrue);
      expect(lines[1].text, '旧待办');
      expect(lines[1].done, isTrue);
      expect(lines[2].text, '普通行');
      expect(lines[2].isTodo, isFalse);
    });

    test('toggleTodoDone flips a line in the document', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final project = store.selected!;
      final controller = store.controllerFor(project);
      controller.replaceText(0, 0, '买牛奶', null);
      final lines = parseDocLines(controller.document.toDelta().toJson());
      store.toggleTodoDone(project, lines.first);
      var groups = groupTodos(
          parseDocLines(controller.document.toDelta().toJson()));
      expect(groups.single.todos.single.done, isTrue);
      store.toggleTodoDone(project, groups.single.todos.single);
      groups = groupTodos(
          parseDocLines(controller.document.toDelta().toJson()));
      expect(groups.single.todos.single.done, isFalse);
    });

    test('clearDone removes only completed todo lines', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final project = store.selected!;
      final controller = store.controllerFor(project);
      controller.replaceText(0, 0, '待办甲\n待办乙\n笔记\n', null);
      final lines = parseDocLines(controller.document.toDelta().toJson());
      // Mark 甲 done, 乙 done-then-open (stays a todo), then clear.
      store.toggleTodoDone(project, lines[0]);
      store.toggleTodoDone(project, lines[1]);
      final refreshed = groupTodos(
          parseDocLines(controller.document.toDelta().toJson()));
      final todoYi = refreshed.single.todos
          .firstWhere((l) => l.text == '待办乙');
      store.toggleTodoDone(project, todoYi);
      store.clearDone(project);
      final plain = controller.document.toPlainText();
      expect(plain, contains('待办乙'));
      expect(plain, contains('笔记'));
      expect(plain, isNot(contains('待办甲')));
    });
  });
}
