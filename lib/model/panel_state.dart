class TaskItem {
  TaskItem({
    required this.id,
    required this.text,
    this.done = false,
  });

  final String id;
  String text;
  bool done;

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        done: json['done'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'done': done,
      };
}

class PanelState {
  PanelState({
    this.note = '',
    List<TaskItem>? items,
    this.alwaysOnTop = true,
    this.x,
    this.y,
    this.width = 390,
    this.height = 520,
  }) : items = items ?? <TaskItem>[];

  String note;
  final List<TaskItem> items;
  bool alwaysOnTop;
  double? x;
  double? y;
  double width;
  double height;

  factory PanelState.fromJson(Map<String, dynamic> json) {
    final window = json['window'] as Map<String, dynamic>? ?? const {};
    final rawItems = json['items'] as List<dynamic>? ?? const [];

    return PanelState(
      note: json['note'] as String? ?? '',
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(TaskItem.fromJson)
          .where((item) => item.id.isNotEmpty)
          .toList(),
      alwaysOnTop: json['alwaysOnTop'] as bool? ?? true,
      x: (window['x'] as num?)?.toDouble(),
      y: (window['y'] as num?)?.toDouble(),
      width: (window['width'] as num?)?.toDouble() ?? 390,
      height: (window['height'] as num?)?.toDouble() ?? 520,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'note': note,
        'items': items.map((item) => item.toJson()).toList(),
        'alwaysOnTop': alwaysOnTop,
        'window': {
          'x': x,
          'y': y,
          'width': width,
          'height': height,
        },
      };
}
