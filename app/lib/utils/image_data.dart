import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

/// Decodes supported raster data URLs without letting corrupt drafts throw
/// during widget construction. Image codec failures are handled by the view.
const maxRestoredIllustrationBytes = 32 * 1024 * 1024;
final _imageHeader = RegExp(
  r'^data:image/(?:png|jpe?g|webp|gif|bmp);base64,',
  caseSensitive: false,
);
final _invalidBase64Character = RegExp(r'[^A-Za-z0-9+/=\s]');
final _base64Whitespace = RegExp(r'\s');

/// Scans for invalid characters without matching the whole payload with a
/// repeated regex group, which can overflow the Dart VM's regexp stack.
String? compactImagePayload(String payload) {
  if (payload.isEmpty ||
      payload.length > ((maxRestoredIllustrationBytes + 2) ~/ 3) * 4 ||
      _invalidBase64Character.hasMatch(payload)) {
    return null;
  }
  return _base64Whitespace.hasMatch(payload)
      ? payload.replaceAll(_base64Whitespace, '')
      : payload;
}

Uint8List? decodeImageData(String source) {
  // Reject oversized drafts before regex matching, whitespace copying or decode.
  if (source.length > ((maxRestoredIllustrationBytes + 2) ~/ 3) * 4 + 128) {
    return null;
  }
  final header = _imageHeader.firstMatch(source);
  if (header == null) return null;
  final payload = compactImagePayload(source.substring(header.end));
  if (payload == null) return null;
  try {
    final bytes = base64Decode(payload);
    return bytes.isEmpty || bytes.length > maxRestoredIllustrationBytes
        ? null
        : bytes;
  } on FormatException {
    return null;
  }
}

/// Decode before insertion, cap memory cost and normalize to the same PNG format
/// accepted by every engine. Animated formats intentionally use their first frame.
Future<String> prepareIllustration(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
    throw const FormatException('image-size');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > 16000000) {
        throw const FormatException('image-size');
      }
      final ratio = math.min(
        1.0,
        2000 / math.max(descriptor.width, descriptor.height),
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * ratio).round()),
        targetHeight: math.max(1, (descriptor.height * ratio).round()),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (png == null) throw const FormatException('image-decode');
          if (png.lengthInBytes > 16 * 1024 * 1024) {
            throw const FormatException('image-size');
          }
          return 'data:image/png;base64,${base64Encode(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes))}';
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
