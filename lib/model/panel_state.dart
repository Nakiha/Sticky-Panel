enum TaskPriority {
  low,
  normal,
  high,
  urgent;

  static TaskPriority fromJson(Object? value) {
    return TaskPriority.values.firstWhere(
      (priority) => priority.name == value,
      orElse: () => TaskPriority.normal,
    );
  }
}

class TaskItem {
  TaskItem({
    required this.id,
    required this.text,
    this.done = false,
    this.priority = TaskPriority.normal,
  });

  final String id;
  String text;
  bool done;
  TaskPriority priority;

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        done: json['done'] as bool? ?? false,
        priority: TaskPriority.fromJson(json['priority']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'done': done,
        'priority': priority.name,
      };
}

class PanelState {
  PanelState({
    this.title = '',
    this.note = '',
    List<TaskItem>? items,
    this.alwaysOnTop = true,
    this.themeMode = 'system',
    this.language = 'system',
    this.fontSize = 15,
    this.fontWeight = 400,
    this.x,
    this.y,
    this.width = 390,
    this.height = 560,
  }) : items = items ?? <TaskItem>[];

  String title;
  String note;
  final List<TaskItem> items;
  bool alwaysOnTop;
  String themeMode;
  String language;
  double fontSize;
  int fontWeight;
  double? x;
  double? y;
  double width;
  double height;

  int get completedCount => items.where((item) => item.done).length;

  factory PanelState.fromJson(Map<String, dynamic> json) {
    final window = json['window'] as Map<String, dynamic>? ?? const {};
    final appearance = json['appearance'] as Map<String, dynamic>? ?? const {};
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    final fontSize = (appearance['fontSize'] as num?)?.toDouble() ?? 15;
    final fontWeight = (appearance['fontWeight'] as num?)?.toInt() ?? 400;

    return PanelState(
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(TaskItem.fromJson)
          .where((item) => item.id.isNotEmpty)
          .toList(),
      alwaysOnTop: json['alwaysOnTop'] as bool? ?? true,
      themeMode: _allowed(
        appearance['themeMode'],
        const {'system', 'light', 'dark'},
        'system',
      ),
      language: _allowed(
        appearance['language'],
        const {'system', 'zh', 'en'},
        'system',
      ),
      fontSize: fontSize.clamp(12, 22).toDouble(),
      fontWeight: const {400, 600, 700}.contains(fontWeight) ? fontWeight : 400,
      x: (window['x'] as num?)?.toDouble(),
      y: (window['y'] as num?)?.toDouble(),
      width: (window['width'] as num?)?.toDouble() ?? 390,
      height: (window['height'] as num?)?.toDouble() ?? 560,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'title': title,
        'note': note,
        'items': items.map((item) => item.toJson()).toList(),
        'alwaysOnTop': alwaysOnTop,
        'appearance': {
          'themeMode': themeMode,
          'language': language,
          'fontSize': fontSize,
          'fontWeight': fontWeight,
        },
        'window': {
          'x': x,
          'y': y,
          'width': width,
          'height': height,
        },
      };

  static String _allowed(
    Object? value,
    Set<String> allowed,
    String fallback,
  ) {
    return value is String && allowed.contains(value) ? value : fallback;
  }
}
