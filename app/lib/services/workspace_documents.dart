import 'dart:convert';
import 'dart:typed_data';

import '../models/detected_paper_layout.dart';
import '../utils/text_tools.dart';
import 'api.dart';
import 'paper_background.dart';
import 'workspace.dart';

/// Document and preset operations are independent of dialogs and file pickers.
class WorkspaceDocuments {
  const WorkspaceDocuments(this.workspace);
  final Workspace workspace;
  static final _selections = Expando<Object>();
  static final _detections = Expando<Object>();

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

  bool applyPaperArea(Upload paper, Map<String, String> layout) {
    if (workspace.disposed || !identical(workspace.background, paper)) {
      return false;
    }
    _detections[workspace] = Object();
    final spacing = double.parse(layout['line_spacing']!);
    final font = double.tryParse(workspace.settings.values['font_size'] ?? '');
    workspace.settings.values.addAll(layout);
    if (font != null && font > spacing) {
      workspace.settings.values['font_size'] = '${(spacing * .72).floor()}';
    }
    workspace.backgroundRuled = true;
    workspace.pages = [];
    workspace.page = 0;
    workspace.edit();
    return true;
  }

  Future<bool> setPaperBackground(Upload file) async {
    final api = workspace.api;
    final token = Object();
    _selections[workspace] = token;
    _detections[workspace] = Object();
    final revision = workspace.backgroundRevision;
    final paper = api.usesMobilePaperLimits
        ? (await preparePaperBackground(
            file,
            mobile: true,
            readPaperExif: api.readPaperExif,
          )).file
        : file;
    if (workspace.disposed ||
        !identical(workspace.api, api) ||
        _selections[workspace] != token ||
        workspace.backgroundRevision != revision) {
      return false;
    }
    workspace.background = paper;
    workspace.pages = [];
    workspace.page = 0;
    workspace.edit();
    return true;
  }

  Future<bool> detectBackground() async {
    final background = workspace.background;
    if (background == null) return false;
    final api = workspace.api;
    final token = Object();
    _detections[workspace] = token;
    final settingsBefore = jsonEncode(workspace.settings.toJson());
    bool current() =>
        !workspace.disposed &&
        identical(workspace.api, api) &&
        workspace.background == background &&
        _detections[workspace] == token &&
        jsonEncode(workspace.settings.toJson()) == settingsBefore;
    final result = await api.importFile('/api/imagefileprocess', background);
    if (!current()) return false;
    var layout = DetectedPaperLayout.fromJson(result);
    Upload? replacement;
    final corrected = result['correctedBackground'];
    if (corrected != null) {
      final size = layout.size;
      if (corrected is! String ||
          corrected.length > 48 * 1024 * 1024 ||
          size == null) {
        throw const FormatException('Invalid corrected background');
      }
      final bytes = base64Decode(corrected);
      final prepared = await preparePaperBackground(
        Upload('aligned-paper.png', bytes),
        mobile: api.usesMobilePaperLimits,
        readPaperExif: api.readPaperExif,
        correctedSize: size,
      );
      layout = layout.scaledTo(prepared.width, prepared.height);
      replacement = prepared.file;
    }
    if (!current()) return false;
    final values = workspace.settings.values;
    values.addAll(layout.settings(values['font_size']));
    if (replacement != null) workspace.background = replacement;
    workspace.backgroundRuled = true;
    workspace.edit();
    return true;
  }
}
