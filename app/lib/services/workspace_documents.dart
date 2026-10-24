import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../utils/text_tools.dart';
import 'api.dart';
import 'workspace.dart';

/// Document and preset operations are independent of dialogs and file pickers.
class WorkspaceDocuments {
  const WorkspaceDocuments(this.workspace);
  final Workspace workspace;
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

  Future<bool> detectBackground() async {
    final background = workspace.background;
    if (background == null) return false;
    final token = Object();
    _detections[workspace] = token;
    final settingsBefore = jsonEncode(workspace.settings.toJson());
    bool current() =>
        !workspace.disposed &&
        workspace.background == background &&
        _detections[workspace] == token &&
        jsonEncode(workspace.settings.toJson()) == settingsBefore;
    final result = await workspace.api.importFile(
      '/api/imagefileprocess',
      background,
    );
    if (!current()) return false;
    int number(String key, {int? fallback, bool positive = false}) {
      final value = result[key] ?? fallback;
      if (value is! num ||
          !value.isFinite ||
          value < (positive ? 1 : 0) ||
          value > 100000) {
        throw const FormatException('Invalid paper identification');
      }
      return value.round();
    }

    final spacing = number('lineSpacing', positive: true);
    final first = number('marginTop');
    final legacyTop = first >= spacing ? first - spacing : first;
    final top = number('layoutTopMargin', fallback: legacyTop);
    final bottom = number(
      'layoutBottomMargin',
      fallback: number('marginBottom'),
    );
    final left = number('marginLeft');
    final right = number('marginRight');
    final width = result.containsKey('imageWidth')
        ? number('imageWidth', positive: true)
        : null;
    final height = result.containsKey('imageHeight')
        ? number('imageHeight', positive: true)
        : null;
    if ((width == null) != (height == null) ||
        (width != null &&
            height != null &&
            (left + right >= width || top + bottom + spacing >= height))) {
      throw const FormatException('Invalid paper dimensions');
    }
    Upload? replacement;
    final corrected = result['correctedBackground'];
    if (corrected != null) {
      if (corrected is! String ||
          corrected.length > 48 * 1024 * 1024 ||
          width == null ||
          height == null) {
        throw const FormatException('Invalid corrected background');
      }
      final bytes = base64Decode(corrected);
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (descriptor.width != width ||
              descriptor.height != height ||
              width * height > 32000000) {
            throw const FormatException(
              'Invalid corrected background dimensions',
            );
          }
          final codec = await descriptor.instantiateCodec();
          try {
            final frame = await codec.getNextFrame();
            frame.image.dispose();
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
      replacement = Upload('aligned-paper.png', bytes);
    }
    if (!current()) return false;
    final fontSize = num.tryParse(workspace.settings.values['font_size'] ?? '');
    workspace.settings.values.addAll({
      if (fontSize != null && fontSize >= spacing)
        'font_size': '${(spacing * 0.72).round().clamp(1, 100000)}',
      'left_margin': '$left',
      'right_margin': '$right',
      'top_margin': '$top',
      'bottom_margin': '$bottom',
      'line_spacing': '$spacing',
      if (width != null) 'width': '$width',
      if (height != null) 'height': '$height',
    });
    if (replacement != null) workspace.background = replacement;
    workspace.backgroundRuled = true;
    workspace.edit();
    return true;
  }
}
