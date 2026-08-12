import 'package:flutter_test/flutter_test.dart';
import 'package:stick_panel/model/panel_state.dart';

void main() {
  test('panel state survives a JSON round trip', () {
    final original = PanelState(
      note: '中文とemoji ✅',
      items: [TaskItem(id: '1', text: 'Ship it', done: true)],
      alwaysOnTop: false,
      x: 120,
      y: 80,
      width: 420,
      height: 600,
    );

    final restored = PanelState.fromJson(original.toJson());

    expect(restored.note, original.note);
    expect(restored.items.single.text, 'Ship it');
    expect(restored.items.single.done, isTrue);
    expect(restored.alwaysOnTop, isFalse);
    expect(restored.x, 120);
    expect(restored.height, 600);
  });
}
