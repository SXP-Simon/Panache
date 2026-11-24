import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/fine_edit.dart';
import '../models/ink_page.dart';
import '../utils/fine_raster.dart';

/// Draws in paper coordinates, keeping perspective handles a constant screen size.
class FinePreviewPainter extends CustomPainter {
  FinePreviewPainter(
    this.raster,
    this.image,
    this.look,
    this.edits, {
    required this.draft,
    required this.outlines,
    required this.corners,
    required this.handleScale,
    required this.box,
    required this.lasso,
    required this.color,
  });
  final FineRaster raster;
  final ui.Image image;
  final InkLook look;
  final Map<int, FineAdjustment> edits;
  final bool draft;
  final Set<Rect> outlines;
  final List<Offset>? corners;
  final double handleScale;
  final Rect? box;
  final List<Offset> lasso;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final fit = size.width / image.width;
    canvas.scale(fit);
    if (draft) {
      raster.paint(canvas, edits, look);
    } else {
      canvas.drawImage(
        image,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    final fill = Paint()..color = color.withValues(alpha: .14);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / fit;
    for (final rect in [...outlines, ?box]) {
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, line);
    }
    if (lasso.length > 1) {
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addPolygon(lasso, true);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, line);
    }
    if (corners case final points?) {
      final scale = fit * handleScale;
      canvas.drawPath(
        Path()..addPolygon(points, true),
        line..strokeWidth = 2 / scale,
      );
      final handle = Paint()..color = color;
      final edge = Paint()..color = Colors.white;
      for (final point in points) {
        canvas.drawCircle(point, 7 / scale, edge);
        canvas.drawCircle(point, 5 / scale, handle);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FinePreviewPainter oldDelegate) => true;
}
