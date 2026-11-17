import 'dart:math' as math;
import 'dart:ui' as ui;

import 'api.dart';

const mobileImageBytes = 16 * 1024 * 1024;
const mobilePaperPixels = 12000000;

/// A resized paper and its actual pixel coordinates belong to the same layout.
Future<({Upload file, int width, int height})> preparePaperBackground(
  Upload file, {
  required bool mobile,
  ({int width, int height})? correctedSize,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(file.bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final width = descriptor.width;
      final height = descriptor.height;
      final originalPixels = width * height;
      if (correctedSize != null &&
          (width != correctedSize.width ||
              height != correctedSize.height ||
              originalPixels > 32000000)) {
        throw const FormatException('Invalid corrected background dimensions');
      }
      if (mobile && originalPixels > 64000000) {
        throw ApiException(
          'Paper source exceeds 64 megapixels',
          code: 'image_limit',
        );
      }

      final reserveForDeskew = correctedSize == null;
      // The Rust detector searches angles up to about 12.5 degrees. Deskew can
      // expand both sides of the image, so leave space for that bounding box.
      final area = reserveForDeskew
          ? originalPixels + ((width * width + height * height) * .22).ceil()
          : originalPixels;
      final resize =
          mobile &&
          (area > mobilePaperPixels || file.bytes.length > mobileImageBytes);
      if (!resize && correctedSize == null) {
        return (file: file, width: width, height: height);
      }
      Future<({Upload file, int width, int height})?> decode(
        double scale,
      ) async {
        final codec = await descriptor.instantiateCodec(
          targetWidth: math.max(1, (width * scale).floor()),
          targetHeight: math.max(1, (height * scale).floor()),
        );
        try {
          final frame = await codec.getNextFrame();
          final image = frame.image;
          try {
            if (!resize) return (file: file, width: width, height: height);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            if (png == null || png.lengthInBytes > mobileImageBytes) {
              return null;
            }
            final stem = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
            return (
              file: Upload(
                '$stem.png',
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              ),
              width: image.width,
              height: image.height,
            );
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }

      final scale = resize ? math.min(1.0, math.sqrt(11800000 / area)) : 1.0;
      final prepared = await decode(scale);
      if (prepared != null) return prepared;
      // A 3.8 MP RGBA image leaves room for PNG overhead within 16 MiB.
      final smaller = await decode(
        math.min(scale, math.sqrt(3800000 / originalPixels)),
      );
      if (smaller != null) return smaller;
      throw ApiException(
        'Could not fit paper within mobile limits',
        code: 'image_limit',
      );
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
