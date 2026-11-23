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

/// Locate the TIFF block without copying a large compressed PNG, WebP or JPEG.
/// Returns the original input for containers handled by the native EXIF reader.
Uint8List? paperExifSource(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final data = ByteData.sublistView(bytes);
  final png =
      data.getUint32(0) == 0x89504e47 && data.getUint32(4) == 0x0d0a1a0a;
  final webp =
      data.getUint32(0) == 0x52494646 && data.getUint32(8) == 0x57454250;
  if (png || webp) {
    var offset = png ? 8 : 12;
    while (offset + 8 <= bytes.length) {
      final type = data.getUint32(offset + (png ? 4 : 0));
      final size = data.getUint32(
        offset + (png ? 0 : 4),
        png ? Endian.big : Endian.little,
      );
      final start = offset + 8;
      final end = start + size;
      if (end > bytes.length) return null;
      if (type == (png ? 0x65584966 : 0x45584946)) {
        // Some WebP writers include the JPEG APP1 prefix before the TIFF header.
        final prefix =
            webp &&
            size >= 6 &&
            data.getUint32(start) == 0x45786966 &&
            data.getUint16(start + 4) == 0;
        return Uint8List.sublistView(bytes, start + (prefix ? 6 : 0), end);
      }
      offset =
          end +
          (png
              ? 4
              : size.isOdd
              ? 1
              : 0);
    }
    return null;
  }
  if (data.getUint16(0) == 0xffd8) {
    var offset = 2;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xda || marker == 0xd9) break;
      if (marker == 1 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) break;
      final size = data.getUint16(offset);
      if (size < 2 || offset + size > bytes.length) break;
      if (marker == 0xe1 &&
          size >= 8 &&
          data.getUint32(offset + 2) == 0x45786966 &&
          data.getUint16(offset + 6) == 0) {
        return Uint8List.sublistView(bytes, offset + 8, offset + size);
      }
      offset += size;
    }
    return null;
  }
  // Non-chunked formats (including TIFF) can store their first IFD in the file header.
  return bytes.length > 64 * 1024 * 1024
      ? Uint8List.sublistView(bytes, 0, 16 * 1024 * 1024)
      : bytes;
}
