import 'dart:convert';
import 'dart:io';

import '../model/panel_state.dart';

class PanelStore {
  PanelStore({File? file}) : _file = file ?? _portableDataFile();

  final File _file;

  String get displayPath => _file.path;

  static File _portableDataFile() {
    final executable = File(Platform.resolvedExecutable);
    return File('${executable.parent.path}${Platform.pathSeparator}StickPanel.data.json');
  }

  Future<PanelState> load() async {
    try {
      if (!await _file.exists()) {
        return PanelState();
      }
      final raw = await _file.readAsString();
      return PanelState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // A damaged file must not prevent a portable note from opening.
      return PanelState();
    }
  }

  Future<void> save(PanelState state) async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    await temporary.writeAsString(encoder.convert(state.toJson()), flush: true);

    if (await _file.exists()) {
      await _file.delete();
    }
    await temporary.rename(_file.path);
  }
}
