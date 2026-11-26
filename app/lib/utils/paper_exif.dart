import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:image/image.dart' as img;

import '../models/settings.dart';

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
  if (data.getUint32(0) == 0x89504e47 && data.getUint32(4) == 0x0d0a1a0a) {
    return _pngExif(data);
  }
  if (data.getUint32(0) == 0x52494646 && data.getUint32(8) == 0x57454250) {
    return _webpExif(data);
  }
  if (data.getUint16(0) == 0xffd8) return _jpegExif(data);
  // Non-chunked formats (including TIFF) can store their first IFD in the file header.
  return bytes.length > 64 * 1024 * 1024
      ? Uint8List.sublistView(bytes, 0, 16 * 1024 * 1024)
      : bytes;
}

Uint8List? _pngExif(ByteData data) {
  var offset = 8;
  while (offset + 8 <= data.lengthInBytes) {
    final start = offset + 8;
    final end = start + data.getUint32(offset);
    if (end > data.lengthInBytes) return null;
    if (data.getUint32(offset + 4) == 0x65584966) {
      return Uint8List.sublistView(data, start, end);
    }
    offset = end + 4; // Skip the chunk CRC.
  }
  return null;
}

Uint8List? _webpExif(ByteData data) {
  var offset = 12;
  while (offset + 8 <= data.lengthInBytes) {
    final start = offset + 8;
    final size = data.getUint32(offset + 4, Endian.little);
    final end = start + size;
    if (end > data.lengthInBytes) return null;
    if (data.getUint32(offset) == 0x45584946) {
      // Some WebP writers include the JPEG APP1 prefix before the TIFF header.
      final tiff = _hasExifPrefix(data, start, end) ? start + 6 : start;
      return Uint8List.sublistView(data, tiff, end);
    }
    offset = end + (size.isOdd ? 1 : 0); // RIFF chunks are word aligned.
  }
  return null;
}

Uint8List? _jpegExif(ByteData data) {
  var offset = 2;
  while (offset < data.lengthInBytes && data.getUint8(offset) == 0xff) {
    do {
      offset++;
    } while (offset < data.lengthInBytes && data.getUint8(offset) == 0xff);
    if (offset == data.lengthInBytes) return null;
    final marker = data.getUint8(offset++);
    if (marker == 0xda || marker == 0xd9) return null;
    if (marker == 1 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > data.lengthInBytes) return null;
    final size = data.getUint16(offset);
    final start = offset + 2;
    final end = offset + size;
    if (size < 2 || end > data.lengthInBytes) return null;
    if (marker == 0xe1 && _hasExifPrefix(data, start, end)) {
      return Uint8List.sublistView(data, start + 6, end);
    }
    offset = end;
  }
  return null;
}

bool _hasExifPrefix(ByteData data, int start, int end) =>
    end - start >= 6 &&
    data.getUint32(start) == 0x45786966 &&
    data.getUint16(start + 4) == 0;

final _cameraFields = Expando<Map<String, String>>();

/// Read only the four device fields used by paper settings. Uploaded byte
/// buffers are replaced on a new selection; avoid parsing on each form edit.
Map<String, String> paperCameraFields(Uint8List bytes) =>
    _cameraFields[bytes] ??= _readCameraFields(bytes);

Map<String, String> _readCameraFields(Uint8List bytes) {
  final source = paperExifSource(bytes);
  if (source == null || source.length < 8) return const {};
  final img.ExifData exif;
  try {
    exif = img.ExifData.fromInputBuffer(img.InputBuffer(source));
  } on RangeError {
    // A broken TIFF offset or an empty thumbnail tag must not break settings.
    return const {};
  }
  final fields = <String, String>{};
  void label(String key, img.IfdValue? entry) {
    if (entry is img.IfdValueAscii &&
        entry.value.isNotEmpty &&
        Settings.validCameraValue(key, entry.value)) {
      fields[key] = entry.value;
    }
  }

  label('camera_make', exif.imageIfd[0x010f]);
  label('camera_model', exif.imageIfd[0x0110]);
  label('camera_lens', exif.exifIfd[0xa434]);
  final iso = exif.exifIfd[0x8827];
  if (iso is img.IfdValueShort && iso.length == 1 && iso.toInt() > 0) {
    fields['camera_iso'] = iso.toInt().toString();
  }
  return Map.unmodifiable(fields);
}
