import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/pdf_pages.dart';

class PdfWritingSurface extends StatefulWidget {
  const PdfWritingSurface({
    super.key,
    required this.page,
    required this.boxes,
    required this.family,
    required this.ink,
    required this.fill,
    required this.onAdd,
    required this.onEdit,
  });
  final PdfSourcePage page;
  final List<PdfWritingBox> boxes;
  final String family;
  final Color ink;
  final bool fill;
  final ValueChanged<Rect> onAdd;
  final ValueChanged<int> onEdit;

  @override
  State<PdfWritingSurface> createState() => _PdfWritingSurfaceState();
}

class _PdfWritingSurfaceState extends State<PdfWritingSurface> {
  Offset? start;
  Rect? drag;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final size = widget.page.size;
        final scale = math.min(
          constraints.maxWidth / size.width,
          constraints.maxHeight / size.height,
        );
        Offset position(Offset local) => Offset(
          (local.dx / scale).clamp(0, size.width),
          (local.dy / scale).clamp(0, size.height),
        );
        return Center(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: GestureDetector(
              key: const ValueKey('pdf-page-surface'),
              dragStartBehavior: DragStartBehavior.down,
              behavior: HitTestBehavior.opaque,
              onPanStart: !widget.fill
                  ? null
                  : (d) => setState(() => start = position(d.localPosition)),
              onPanUpdate: !widget.fill
                  ? null
                  : (d) {
                      if (start != null) {
                        setState(
                          () => drag = Rect.fromPoints(
                            start!,
                            position(d.localPosition),
                          ),
                        );
                      }
                    },
              onPanCancel: () => setState(() {
                start = null;
                drag = null;
              }),
              onPanEnd: !widget.fill
                  ? null
                  : (_) {
                      final area = drag;
                      setState(() {
                        start = null;
                        drag = null;
                      });
                      if (area != null &&
                          area.width * scale >= 8 &&
                          area.height * scale >= 6) {
                        widget.onAdd(area);
                      }
                    },
              onTapUp: (d) {
                final point = position(d.localPosition);
                final index = widget.boxes.lastIndexWhere(
                  (box) => box.rect.contains(point),
                );
                if (index >= 0) widget.onEdit(index);
              },
              child: SizedBox(
                width: size.width * scale,
                height: size.height * scale,
                child: CustomPaint(
                  foregroundPainter: _WritingPainter(
                    widget.boxes,
                    widget.family,
                    widget.ink,
                    scale,
                    drag,
                    Theme.of(context).colorScheme.primary,
                  ),
                  child: Image.memory(
                    widget.page.paper,
                    fit: BoxFit.fill,
                    gaplessPlayback: false,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WritingPainter extends CustomPainter {
  const _WritingPainter(
    this.boxes,
    this.family,
    this.ink,
    this.scale,
    this.drag,
    this.selectionColor,
  );
  final List<PdfWritingBox> boxes;
  final String family;
  final Color ink, selectionColor;
  final double scale;
  final Rect? drag;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale);
    paintPdfWriting(canvas, boxes, family, ink);
    if (drag case final area?) {
      canvas.drawRect(
        area,
        Paint()..color = selectionColor.withValues(alpha: .14),
      );
      canvas.drawRect(
        area,
        Paint()
          ..color = selectionColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale,
      );
    }
  }

  @override
  bool shouldRepaint(_WritingPainter old) =>
      old.boxes != boxes ||
      old.family != family ||
      old.ink != ink ||
      old.scale != scale ||
      old.drag != drag ||
      old.selectionColor != selectionColor;
}
