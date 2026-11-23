import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/paper_area.dart';
import '../../utils/lasso.dart';

class PaperAreaDialog extends StatefulWidget {
  const PaperAreaDialog({
    super.key,
    required this.bytes,
    required this.size,
    required this.values,
  });

  final Uint8List bytes;
  final Size size;
  final Map<String, String> values;

  @override
  State<PaperAreaDialog> createState() => _PaperAreaDialogState();
}

class _PaperAreaDialogState extends State<PaperAreaDialog> {
  late final double spacing;
  late Rect area;
  late final TextEditingController rows;
  Offset? anchor;
  Rect? previous;
  int? activePointer;
  bool editedRows = false;
  bool free = false;
  Rect? enclosed;
  List<Offset> path = [];
  List<Offset> shownPath = [];

  Rect? get writingArea => free ? enclosed : area;

  double value(String key, double fallback) {
    final parsed = double.tryParse(widget.values[key] ?? '');
    return parsed != null && parsed.isFinite ? parsed : fallback;
  }

  @override
  void initState() {
    super.initState();
    final size = widget.size;
    spacing = math.max(
      1,
      math.min(
        (size.height * .16).floorToDouble(),
        math.max(8, value('line_spacing', 60)),
      ),
    );
    area = Rect.fromLTRB(
      value('left_margin', 0).clamp(0, size.width * .3),
      (value('top_margin', 0) + spacing).clamp(0, size.height * .55),
      (size.width - value('right_margin', 0)).clamp(
        size.width * .7,
        size.width,
      ),
      (size.height - value('bottom_margin', 0) - (spacing / 4).ceil()).clamp(
        size.height * .65,
        size.height - 1,
      ),
    );
    rows = TextEditingController(text: suggestedRows);
  }

  String get suggestedRows {
    final area = writingArea;
    return area == null
        ? ''
        : '${math.max(2, (area.height / spacing).round() + (free ? 0 : 1))}';
  }

  Offset point(Offset screenPoint, double scale) {
    final next = screenPoint / scale;
    return Offset(
      next.dx.clamp(0, widget.size.width),
      next.dy.clamp(0, widget.size.height - 1),
    );
  }

  @override
  void dispose() {
    rows.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event, double scale) {
    if (activePointer != null || event.buttons != kPrimaryButton) return;
    activePointer = event.pointer;
    final point = this.point(event.localPosition, scale);
    if (free) {
      setState(() {
        path = [point];
        shownPath = path;
        enclosed = null;
      });
      return;
    }
    previous = area;
    anchor = point;
    final corners = [
      area.topLeft,
      area.topRight,
      area.bottomLeft,
      area.bottomRight,
    ];
    final hit = corners.indexWhere(
      (corner) => (corner - point).distance * scale <= 19,
    );
    if (hit >= 0) anchor = corners[3 - hit];
  }

  void _pointerMove(PointerMoveEvent event, double scale) {
    if (activePointer != event.pointer) return;
    final next = point(event.localPosition, scale);
    if (free) {
      appendLassoPoint(path, next, 4 / scale);
      setState(() => shownPath = [...path, next]);
      return;
    }
    final start = anchor;
    if (start == null) return;
    setState(() {
      area = Rect.fromPoints(start, next);
      if (!editedRows) rows.text = suggestedRows;
    });
  }

  void _pointerUp(PointerUpEvent event, double scale) {
    if (activePointer != event.pointer) return;
    activePointer = null;
    if (!free) return;
    setState(() {
      shownPath = [...path, point(event.localPosition, scale)];
      enclosed = enclosedRectangle(shownPath);
      if (!editedRows) rows.text = suggestedRows;
    });
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (activePointer != event.pointer) return;
    if (free) {
      setState(() {
        path = [];
        shownPath = [];
        enclosed = null;
      });
    } else if (previous != null) {
      setState(() => area = previous!);
    }
    if (!editedRows) rows.text = suggestedRows;
    activePointer = null;
  }

  Widget _paperSurface(Rect? paper, Map<String, String>? layout, int count) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = math.min(
          540.0,
          MediaQuery.sizeOf(context).height * .50,
        );
        final scale = math.min(
          constraints.maxWidth / widget.size.width,
          maxHeight / widget.size.height,
        );
        double? firstLine, step;
        if (free && layout != null) {
          final spacing = int.parse(layout['line_spacing']!);
          firstLine = (int.parse(layout['top_margin']!) + spacing) * scale;
          step = spacing * scale;
        }
        final scaledArea = paper == null
            ? null
            : Rect.fromLTRB(
                paper.left * scale,
                paper.top * scale,
                paper.right * scale,
                paper.bottom * scale,
              );
        return Center(
          child: SizedBox(
            width: widget.size.width * scale,
            height: widget.size.height * scale,
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: RawGestureDetector(
                key: const ValueKey('paper-area-image'),
                behavior: HitTestBehavior.opaque,
                gestures: {
                  EagerGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        EagerGestureRecognizer
                      >(EagerGestureRecognizer.new, (_) {}),
                },
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => _pointerDown(event, scale),
                  onPointerMove: (event) => _pointerMove(event, scale),
                  onPointerUp: (event) => _pointerUp(event, scale),
                  onPointerCancel: _pointerCancel,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(widget.bytes, fit: BoxFit.fill),
                      CustomPaint(
                        painter: _PaperAreaPainter(
                          scaledArea,
                          layout == null ? 0 : count,
                          path: free
                              ? [for (final point in shownPath) point * scale]
                              : [],
                          firstLine: firstLine,
                          step: step,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final count = int.tryParse(rows.text) ?? 0;
    final paper = writingArea;
    final layout = paper == null
        ? null
        : paperAreaLayout(paper, widget.size, count, enclosed: free);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.paperAreaTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(l.fineBox)),
                    ButtonSegment(value: true, label: Text(l.fineLasso)),
                  ],
                  selected: {free},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) => setState(() {
                    free = selection.first;
                    if (!editedRows) rows.text = suggestedRows;
                  }),
                ),
              ),
              const SizedBox(height: 8),
              Text(free ? l.paperAreaLassoHelp : l.paperAreaHelp),
              const SizedBox(height: 12),
              _paperSurface(paper, layout, count),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 145,
                    child: TextField(
                      key: const ValueKey('paper-area-rows'),
                      controller: rows,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: l.paperAreaRows),
                      onChanged: (_) => setState(() => editedRows = true),
                    ),
                  ),
                  Text(
                    layout == null
                        ? l.paperAreaInvalid
                        : l.paperAreaSpacing(layout['line_spacing']!),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.cancel),
                  ),
                  FilledButton(
                    key: const ValueKey('paper-area-apply'),
                    onPressed: layout == null
                        ? null
                        : () => Navigator.pop(context, layout),
                    child: Text(l.paperAreaApply),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaperAreaPainter extends CustomPainter {
  const _PaperAreaPainter(
    this.area,
    this.rows, {
    required this.path,
    required this.firstLine,
    required this.step,
  });
  final Rect? area;
  final int rows;
  final List<Offset> path;
  final double? firstLine, step;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = const Color(0xff294e1a)
      ..strokeWidth = 1.5;
    final marker = Paint()..color = const Color(0xffa8ed53);
    final fill = Paint()..color = const Color(0x28a8ed53);
    if (path.length > 1) {
      final outline = Path()
        ..fillType = PathFillType.evenOdd
        ..addPolygon(path, true);
      canvas.drawPath(outline, fill);
      canvas.drawPath(outline, border..style = PaintingStyle.stroke);
    }
    final area = this.area;
    if (area == null) return;
    canvas.drawRect(area, Paint()..color = const Color(0x28a8ed53));
    canvas.drawRect(area, border..style = PaintingStyle.stroke);
    if (path.isNotEmpty) {
      if (firstLine != null && step != null) {
        for (var i = 0; i < rows; i++) {
          final y = firstLine! + i * step!;
          canvas.drawLine(
            Offset(area.left, y),
            Offset(area.right, y),
            border..strokeWidth = .65,
          );
        }
      }
      return;
    }
    for (var line = 1; line < rows - 1; line++) {
      final y = area.top + area.height * line / (rows - 1);
      canvas.drawLine(
        Offset(area.left, y),
        Offset(area.right, y),
        border..strokeWidth = .65,
      );
    }
    for (final corner in [
      area.topLeft,
      area.topRight,
      area.bottomLeft,
      area.bottomRight,
    ]) {
      canvas.drawCircle(corner, 6, marker);
      canvas.drawCircle(corner, 6, border..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_PaperAreaPainter oldDelegate) =>
      area != oldDelegate.area ||
      rows != oldDelegate.rows ||
      path != oldDelegate.path ||
      firstLine != oldDelegate.firstLine ||
      step != oldDelegate.step;
}
