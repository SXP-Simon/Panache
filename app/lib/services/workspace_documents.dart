import 'dart:convert';
import 'dart:typed_data';

import '../utils/text_tools.dart';
import 'api.dart';
import 'workspace.dart';

/// Document and preset operations are independent of dialogs and file pickers.
class WorkspaceDocuments {
  const WorkspaceDocuments(this.workspace);
  final Workspace workspace;

  Future<void> importText(Upload file) async {
    final result = await workspace.api.importFile('/api/textfileprocess', file);
    if (workspace.disposed) return;
    workspace.text = collapseImages(result['text'] as String, workspace.images);
    workspace.edit();
  }

  Uint8List exportPreset() =>
      Uint8List.fromList(utf8.encode(jsonEncode(workspace.settings.toJson())));

  void importPreset(Upload file) {
    final data = jsonDecode(utf8.decode(file.bytes));
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a settings object');
    }
    final previousFont = workspace.settings.font;
    workspace.settings.restore(data);
    if (!workspace.fonts.contains(workspace.settings.font)) {
      workspace.settings.font = previousFont;
    }
    workspace.edit();
  }

  Future<void> detectBackground() async {
    final background = workspace.background;
    if (background == null) return;
    final result = await workspace.api.importFile(
      '/api/imagefileprocess',
      background,
    );
    if (workspace.disposed || workspace.background != background) return;
    const fields = {
      'marginLeft': 'left_margin',
      'marginRight': 'right_margin',
      'marginTop': 'top_margin',
      'marginBottom': 'bottom_margin',
      'lineSpacing': 'line_spacing',
    };
    for (final field in fields.entries) {
      final value = result[field.key];
      if (value is num && value.isFinite && value >= 0) {
        workspace.settings.values[field.value] = '${value.round()}';
      }
    }
    workspace.edit();
  }
}
