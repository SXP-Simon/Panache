import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// Attach the engine's filtered TIFF payload to a freshly encoded Flutter PNG.
Uint8List withPaperExif(Uint8List png, Uint8List? exif) {
  if (exif == null || exif.isEmpty) return png;
  // The PNG signature and required 13-byte IHDR occupy the first 33 bytes.
  const afterHeader = 33;
  final chunkLength = 12 + exif.length;
  final out = Uint8List(png.length + chunkLength);
  final data = ByteData.sublistView(out);
  out.setRange(0, afterHeader, png);
  data.setUint32(afterHeader, exif.length);
  data.setUint32(afterHeader + 4, 0x65584966); // eXIf
  out.setRange(afterHeader + 8, afterHeader + 8 + exif.length, exif);
  final crcOffset = afterHeader + 8 + exif.length;
  data.setUint32(
    crcOffset,
    getCrc32(Uint8List.sublistView(out, afterHeader + 4, crcOffset)),
  );
  out.setRange(afterHeader + chunkLength, out.length, png, afterHeader);
  return out;
}
