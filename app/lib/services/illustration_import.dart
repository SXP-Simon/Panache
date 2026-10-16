import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'api.dart';

const maxIllustrationImportBytes = 12 * 1024 * 1024;

/// Inspect declared size before opening the stream and enforce the same limit
/// while reading: cloud providers can report a stale or unknown file size.
Future<Upload> readIllustrationFile(PlatformFile file) async {
  if (file.size < 0 || file.size > maxIllustrationImportBytes) {
    throw const FormatException('image-size');
  }
  final stream = file.readStream;
  if (stream != null) {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxIllustrationImportBytes) {
        throw const FormatException('image-size');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) throw const FormatException('image-empty');
    return Upload(file.name, bytes);
  }
  // Some adapters already provide bounded bytes. Never fall back to an
  // unbounded file read if a platform cannot supply the requested stream.
  final bytes = file.bytes;
  if (bytes == null ||
      bytes.isEmpty ||
      bytes.length > maxIllustrationImportBytes) {
    throw const FormatException('image-unreadable');
  }
  return Upload(file.name, bytes);
}

Future<Upload?> pickIllustration({FilePicker? picker}) async {
  final result = await (picker ?? FilePicker.platform).pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    withData: false,
    withReadStream: true,
  );
  if (result == null) return null;
  if (result.files.length != 1) throw const FormatException('image-selection');
  return readIllustrationFile(result.files.single);
}
