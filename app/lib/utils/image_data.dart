import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

/// Decodes supported raster data URLs without letting corrupt drafts throw
/// during widget construction. Image codec failures are handled by the view.
const maxRestoredIllustrationBytes = 32 * 1024 * 1024;

Uint8List? decodeImageData(String source) {
  // Reject oversized drafts before regex matching, whitespace copying or decode.
  if (source.length > ((maxRestoredIllustrationBytes + 2) ~/ 3) * 4 + 128) {
    return null;
  }
  final match = RegExp(
    r'^data:image/(?:png|jpe?g|webp|gif|bmp);base64,([A-Za-z0-9+/=\s]+)$',
    caseSensitive: false,
  ).firstMatch(source);
  if (match == null) return null;
  try {
    final bytes = base64Decode(match[1]!.replaceAll(RegExp(r'\s'), ''));
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
          return 'data:image/png;base64,${base64Encode(png.buffer.asUint8List())}';
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
