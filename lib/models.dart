/// Data models for Sticky Panel.
///
/// Everything is plain JSON-serializable objects so persistence stays simple.
library;

/// A single line in a project list.
///
/// Lines are all born equal: a plain note line and a todo line are the same
/// object, differing only by [isTodo]. Any line can be flipped between the
/// two in place, so notes can be "promoted" to todos without retyping.
class Entry {
  Entry({
    required this.id,
    required this.text,
    this.isTodo = false,
    this.done = false,
    this.bold = false,
    this.highlight = 0,
    this.fontSize = 14.0,
  });

  final String id;
  String text;

  /// Whether this line shows a checkbox and behaves as a task.
  bool isTodo;

  /// Completion state; only meaningful when [isTodo] is true.
  bool done;

  /// Whether the text renders in bold.
  bool bold;

  /// ARGB color value for the text background; 0 means no highlight.
  int highlight;

  /// Logical font size for this line.
  double fontSize;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'isTodo': isTodo,
        'done': done,
        'bold': bold,
        'highlight': highlight,
        'fontSize': fontSize,
      };

  factory Entry.fromJson(Map<String, dynamic> json) => Entry(
        id: json['id'] as String,
        text: json['text'] as String? ?? '',
        isTodo: json['isTodo'] as bool? ?? false,
        done: json['done'] as bool? ?? false,
        bold: json['bold'] as bool? ?? false,
        highlight: (json['highlight'] as num?)?.toInt() ?? 0,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14.0,
      );
}

/// A named list of entries (one per project the user is tracking).
class Project {
  Project({required this.id, required this.name, List<Entry>? entries})
      : entries = entries ?? <Entry>[];

  final String id;
  String name;
  final List<Entry> entries;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        name: json['name'] as String? ?? '未命名项目',
        entries: (json['entries'] as List<dynamic>? ?? [])
            .map((e) => Entry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
