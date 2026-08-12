import 'package:flutter_test/flutter_test.dart';
import 'package:stick_panel/model/panel_state.dart';

void main() {
  test('panel state survives a JSON round trip', () {
    final original = PanelState(
      title: 'Ship v0.3',
      note: '中文とemoji ✅',
      items: [
        TaskItem(
          id: '1',
          text: 'Ship it',
          done: true,
          priority: TaskPriority.urgent,
        ),
        TaskItem(id: '2', text: 'Write notes'),
      ],
      alwaysOnTop: false,
      themeMode: 'dark',
      language: 'zh',
      fontSize: 18,
      fontWeight: 600,
      x: 120,
      y: 80,
      width: 420,
      height: 600,
    );

    final restored = PanelState.fromJson(original.toJson());

    expect(restored.title, 'Ship v0.3');
    expect(restored.note, original.note);
    expect(restored.items.first.text, 'Ship it');
    expect(restored.items.first.done, isTrue);
    expect(restored.items.first.priority, TaskPriority.urgent);
    expect(restored.items.last.priority, TaskPriority.normal);
    expect(restored.completedCount, 1);
    expect(restored.alwaysOnTop, isFalse);
    expect(restored.themeMode, 'dark');
    expect(restored.language, 'zh');
    expect(restored.fontSize, 18);
    expect(restored.fontWeight, 600);
    expect(restored.x, 120);
    expect(restored.height, 600);
  });

  test('version 1 data keeps safe version 2 defaults', () {
    final restored = PanelState.fromJson({
      'version': 1,
      'note': 'old note',
      'items': [
        {'id': 'legacy', 'text': 'old task', 'done': false},
      ],
      'alwaysOnTop': true,
      'window': {'width': 390, 'height': 520},
    });

    expect(restored.title, isEmpty);
    expect(restored.items.single.priority, TaskPriority.normal);
    expect(restored.themeMode, 'system');
    expect(restored.language, 'system');
    expect(restored.fontSize, 15);
    expect(restored.fontWeight, 400);
  });

  test('appearance values are validated and clamped', () {
    final restored = PanelState.fromJson({
      'appearance': {
        'themeMode': 'neon',
        'language': 'jp',
        'fontSize': 99,
        'fontWeight': 500,
      },
    });

    expect(restored.themeMode, 'system');
    expect(restored.language, 'system');
    expect(restored.fontSize, 22);
    expect(restored.fontWeight, 400);
  });
}
