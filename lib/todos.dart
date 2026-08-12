/// Pure parsing helpers that turn a Quill delta (its JSON op list) into
/// lines and todo groups. Kept free of Flutter/quill imports so it is
/// trivially unit-testable.
library;

/// One logical line of a Quill document.
class DocLine {
  const DocLine({
    required this.start,
    required this.length,
    required this.text,
    this.list,
    this.header,
  });

  /// Character offset of the line start in the document.
  final int start;

  /// Text length of the line, excluding the trailing newline.
  final int length;

  /// Plain text of the line (no trailing newline).
  final String text;

  /// Value of the line's `list` attribute, e.g. `checked` / `unchecked`.
  final String? list;

  /// Value of the line's `header` attribute (heading level), if any.
  final int? header;

  bool get isTodo => list == 'checked' || list == 'unchecked';
  bool get done => list == 'checked';
  bool get isHeader => header != null;
}

/// Todos belonging to one section (the nearest heading above them).
class TodoGroup {
  const TodoGroup({required this.title, required this.todos});

  final String title;
  final List<DocLine> todos;
}

/// Label used for todos that appear before any heading.
const String kUngroupedTitle = '未分组';

/// Split a delta JSON op list (`document.toDelta().toJson()`) into lines.
///
/// Line attributes in Quill live on the op that contains the line's trailing
/// `\n`, so each line inherits the attributes of the op its newline came from.
List<DocLine> parseDocLines(List<dynamic> ops) {
  final lines = <DocLine>[];
  final buffer = StringBuffer();
  var offset = 0;
  var lineStart = 0;

  void endLine(Map<String, dynamic>? attributes) {
    final listValue = attributes?['list'];
    final headerValue = attributes?['header'];
    lines.add(DocLine(
      start: lineStart,
      length: buffer.length,
      text: buffer.toString(),
      list: listValue is String ? listValue : null,
      header: headerValue is num ? headerValue.toInt() : null,
    ));
    buffer.clear();
  }

  for (final op in ops) {
    if (op is! Map) continue;
    final data = op['insert'];
    final attributes = (op['attributes'] as Map?)?.cast<String, dynamic>();
    if (data is String) {
      final parts = data.split('\n');
      for (var i = 0; i < parts.length; i++) {
        buffer.write(parts[i]);
        offset += parts[i].length;
        if (i < parts.length - 1) {
          // Consumed a newline: the current line ends here.
          endLine(attributes);
          offset += 1;
          lineStart = offset;
        }
      }
    } else if (data != null) {
      // Embeds occupy one character; treat them as an opaque placeholder.
      buffer.write('￼');
      offset += 1;
    }
  }
  return lines;
}

/// Group todo lines by the nearest heading above them.
///
/// Dart maps preserve insertion order, so groups follow document order.
List<TodoGroup> groupTodos(List<DocLine> lines) {
  final groups = <String, List<DocLine>>{};
  var section = kUngroupedTitle;
  for (final line in lines) {
    if (line.isHeader) {
      section = line.text.isEmpty ? kUngroupedTitle : line.text;
    }
    if (line.isTodo && line.text.isNotEmpty) {
      groups.putIfAbsent(section, () => []).add(line);
    }
  }
  return [
    for (final entry in groups.entries)
      TodoGroup(title: entry.key, todos: entry.value),
  ];
}
