import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sticky_panel/models.dart';
import 'package:sticky_panel/todos.dart';

void main() {
  test('project json round-trip preserves the document', () {
    final project = Project(id: 'p1', name: '项目A', docJson: '[{"insert":"hi\\n"}]');
    final restored = Project.fromJson(jsonDecode(jsonEncode(project.toJson())));
    expect(restored.id, 'p1');
    expect(restored.name, '项目A');
    expect(restored.docJson, project.docJson);
  });

  test('parseTodoSpans finds open and done spans', () {
    final ops = [
      {'insert': '随便记点东西\n'},
      {
        'insert': '跟进合同',
        'attributes': {'todo': 'open', 'underline': true}
      },
      {'insert': '\n普通行\n'},
      {
        'insert': '已完成的事',
        'attributes': {'todo': 'done', 'underline': true, 'strike': true}
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
      {'insert': '无标题待办', 'attributes': {'todo': 'open'}},
      {'insert': '\n'},
      {'insert': '客户端'},
      {
        'insert': '\n',
        'attributes': {'header': 2}
      },
      {'insert': '修崩溃', 'attributes': {'todo': 'open'}},
      {'insert': '\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.length, 2);
    expect(spans[0].section, kUngroupedTitle);
    expect(spans[1].section, '客户端');
  });

  test('parseTodoSpans merges adjacent ops with the same state', () {
    final ops = [
      {'insert': '前半', 'attributes': {'todo': 'open'}},
      {
        'insert': '后半',
        'attributes': {'todo': 'open', 'bold': true}
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
      {'insert': '甲乙', 'attributes': {'todo': 'open'}},
      {'insert': '丙', 'attributes': {'todo': 'done'}},
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
      {'insert': '目标', 'attributes': {'todo': 'open'}},
      {'insert': '尾巴\n'},
    ];
    final spans = parseTodoSpans(ops);
    expect(spans.single.start, 4);
    expect(spans.single.length, 2);
  });
}
