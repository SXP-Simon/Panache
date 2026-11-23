import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import '../models/engine_failure.dart';
import '../models/upload.dart';
import '../utils/paper_exif.dart';

const mobileImageBytes = 16 * 1024 * 1024;
const mobilePaperPixels = 12000000;

/// A resized paper and its actual pixel coordinates belong to the same layout.
Future<({Upload file, int width, int height})> preparePaperBackground(
  Upload file, {
  required bool mobile,
  Future<Uint8List?> Function(Upload)? readPaperExif,
  ({int width, int height})? correctedSize,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(file.bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final width = descriptor.width;
      final height = descriptor.height;
      final plan = _decodePlan(
        width,
        height,
        file.bytes.length,
        mobile: mobile,
        correctedSize: correctedSize,
      );
      if (!plan.resize && correctedSize == null) {
        return (file: file, width: width, height: height);
      }
      final exif = plan.resize ? await readPaperExif?.call(file) : null;
      for (final scale in plan.scales) {
        final prepared = await _decodePaper(
          descriptor,
          file,
          scale: scale,
          resize: plan.resize,
          exif: exif,
        );
        if (prepared != null) return prepared;
      }
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

({bool resize, List<double> scales}) _decodePlan(
  int width,
  int height,
  int byteLength, {
  required bool mobile,
  required ({int width, int height})? correctedSize,
}) {
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
      mobile && (area > mobilePaperPixels || byteLength > mobileImageBytes);
  if (!resize) return (resize: false, scales: const [1.0]);
  final initial = math.min(1.0, math.sqrt(11800000 / area));
  // A 3.8 MP RGBA image leaves room for PNG overhead within 16 MiB.
  final fallback = math.min(initial, math.sqrt(3800000 / originalPixels));
  return (resize: true, scales: [initial, fallback]);
}

Future<({Upload file, int width, int height})?> _decodePaper(
  ui.ImageDescriptor descriptor,
  Upload file, {
  required double scale,
  required bool resize,
  required Uint8List? exif,
}) async {
  final codec = await descriptor.instantiateCodec(
    targetWidth: math.max(1, (descriptor.width * scale).floor()),
    targetHeight: math.max(1, (descriptor.height * scale).floor()),
  );
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      if (!resize) {
        return (file: file, width: descriptor.width, height: descriptor.height);
      }
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null ||
          png.lengthInBytes +
                  (exif == null || exif.isEmpty ? 0 : exif.length + 12) >
              mobileImageBytes) {
        return null;
      }
      final stem = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      return (
        file: Upload(
          '$stem.png',
          withPaperExif(Uint8List.sublistView(png), exif),
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
