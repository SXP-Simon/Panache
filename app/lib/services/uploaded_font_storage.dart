import 'dart:convert';
import 'dart:typed_data';

import 'api.dart';
import 'uploaded_font_storage_native.dart'
    if (dart.library.js_interop) 'uploaded_font_storage_web.dart'
    as platform;

/// Uploaded font bytes belong in binary storage, outside preference snapshots.
abstract interface class UploadedFontStorage {
  Future<Upload?> read();
  Future<void> write(Upload? font);
}

UploadedFontStorage createUploadedFontStorage() => platform.FontStorage();

Uint8List encodeFont(Upload font) {
  final name = utf8.encode(font.name);
  final result = Uint8List(4 + name.length + font.bytes.length);
  ByteData.sublistView(result).setUint32(0, name.length);
  result.setRange(4, 4 + name.length, name);
  result.setRange(4 + name.length, result.length, font.bytes);
  return result;
}

Upload decodeFont(Uint8List data) {
  if (data.length < 5) throw const FormatException('Invalid saved font');
  final length = ByteData.sublistView(data).getUint32(0);
  if (length == 0 || length >= data.length - 4) {
    throw const FormatException('Invalid saved font');
  }
  return Upload(
    utf8.decode(data.sublist(4, 4 + length)),
    Uint8List.sublistView(data, 4 + length),
  );
}
