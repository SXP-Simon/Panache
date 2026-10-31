import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

/// Copies the rendered PNG itself, without exporting a file or a file URI.
Future<void> copyPreviewImage(Uint8List png) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    throw UnsupportedError('Image clipboard is unavailable');
  }
  final item = DataWriterItem()..add(Formats.png(png));
  await clipboard.write([item]);
}
