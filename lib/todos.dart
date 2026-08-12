/// Pure parsing helpers that turn a Quill delta (its JSON op list) into todo
/// spans. Kept free of Flutter/quill imports so it is trivially unit-testable.
library;

/// Attribute key marking a text span as a todo. Value is 'open' or 'done'.
const String kTodoAttributeKey = 'todo';

/// Label used for todos that appear before any heading.
const String kUngroupedTitle = '未分组';

/// A contiguous run of text carrying the todo attribute.
class TodoSpan {
  const TodoSpan({
    required this.start,
    required this.length,
    required this.text,
    required this.done,
    required this.section,
  });

  /// Character offset of the span start in the document.
  final int start;

  /// Text length of the span.
  final int length;

  /// Plain text of the span (newlines replaced by spaces, trimmed).
  final String text;

  final bool done;

  /// Text of the nearest heading line above the span, or [kUngroupedTitle].
  final String section;
}

/// Extract todo spans from a delta JSON op list
/// (`document.toDelta().toJson()`).
///
/// Adjacent ops with the same todo state merge into one span. The section of
/// a span is the nearest heading line above its start: line attributes in
/// Quill live on the op containing the line's trailing `\n`, so a newline op
/// with a `header` attribute renames the section for everything after it.
List<TodoSpan> parseTodoSpans(List<dynamic> ops) {
  final spans = <TodoSpan>[];
  final lineBuffer = StringBuffer();
  var offset = 0;
  var section = kUngroupedTitle;

  // Current open span being accumulated.
  int? spanStart;
  var spanLength = 0;
  var spanDone = false;
  var spanSection = kUngroupedTitle;
  final spanText = StringBuffer();

  void flushSpan() {
    if (spanStart == null) return;
    final text = spanText.toString().replaceAll('\n', ' ').trim();
    if (text.isNotEmpty) {
      spans.add(TodoSpan(
        start: spanStart!,
        length: spanLength,
        text: text,
        done: spanDone,
        section: spanSection,
      ));
    }
    spanStart = null;
    spanLength = 0;
    spanText.clear();
  }

  for (final op in ops) {
    if (op is! Map) continue;
    final data = op['insert'];
    final attributes = (op['attributes'] as Map?)?.cast<String, dynamic>();
    if (data is! String) {
      // Embeds occupy one character and break any open span.
      if (data != null) {
        flushSpan();
        offset += 1;
      }
      continue;
    }

    final todoValue = attributes?[kTodoAttributeKey];
    final isTodo = todoValue == 'open' || todoValue == 'done';
    final done = todoValue == 'done';
    final isHeader = attributes?['header'] != null;

    final parts = data.split('\n');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isNotEmpty) {
        if (isTodo) {
          if (spanStart != null && spanDone != done) flushSpan();
          if (spanStart == null) {
            spanStart = offset;
            spanSection = section;
          }
          spanDone = done;
          spanLength += part.length;
          spanText.write(part);
        } else {
          flushSpan();
        }
        lineBuffer.write(part);
        offset += part.length;
      }
      if (i < parts.length - 1) {
        // A newline always ends a todo span; a heading line renames the
        // section for the following content.
        flushSpan();
        if (isHeader) {
          section =
              lineBuffer.isEmpty ? kUngroupedTitle : lineBuffer.toString();
        }
        lineBuffer.clear();
        offset += 1;
      }
    }
  }
  flushSpan();
  return spans;
}
