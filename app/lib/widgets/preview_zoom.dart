import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

// Generated pages are PNGs. Reading their dimensions doesn't decode the pixels twice.
Size? previewPngSize(Uint8List png) {
  if (png.length < 24) return null;
  final header = ByteData.sublistView(png, 0, 24);
  if (header.getUint32(0) != 0x89504e47 ||
      header.getUint32(4) != 0x0d0a1a0a ||
      header.getUint32(12) != 0x49484452) {
    return null;
  }
  final size = Size(
    header.getUint32(16).toDouble(),
    header.getUint32(20).toDouble(),
  );
  return size.isEmpty ? null : size;
}

Matrix4 initialPreviewZoom(Size viewport, Size paper, {double contentTop = 0}) {
  final fit = math.min(
    viewport.width / paper.width,
    viewport.height / paper.height,
  );
  final scale = (viewport.width * .86 / (paper.width * fit)).clamp(1.0, 3.0);
  if (scale == 1) return Matrix4.identity();
  final height = paper.height * fit;
  final travel = math.max(0.0, height * scale - viewport.height);
  final top = (contentTop * fit * scale - 24).clamp(0.0, travel);
  return Matrix4.identity()
    ..translateByDouble(
      viewport.width * (1 - scale) / 2,
      -(viewport.height - height) * scale / 2 - top,
      0,
      1,
    )
    ..scaleByDouble(scale, scale, scale, 1);
}
