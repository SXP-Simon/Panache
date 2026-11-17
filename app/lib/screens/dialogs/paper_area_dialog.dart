import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/paper_area.dart';

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

  String get suggestedRows =>
      '${math.max(2, (area.height / spacing).round() + 1)}';

  @override
  void dispose() {
    rows.dispose();
    super.dispose();
  }

  void start(Offset screenPoint, double scale) {
    final point = screenPoint / scale;
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

  void move(Offset screenPoint, double scale) {
    final start = anchor;
    if (start == null) return;
    final next = screenPoint / scale;
    setState(() {
      area = Rect.fromPoints(
        start,
        Offset(
          next.dx.clamp(0, widget.size.width),
          next.dy.clamp(0, widget.size.height - 1),
        ),
      );
      if (!editedRows) rows.text = suggestedRows;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final count = int.tryParse(rows.text) ?? 0;
    final layout = paperAreaLayout(area, widget.size, count);
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
              Text(l.paperAreaHelp),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final maxHeight = math.min(
                    540.0,
                    MediaQuery.sizeOf(context).height * .50,
                  );
                  final scale = math.min(
                    constraints.maxWidth / widget.size.width,
                    maxHeight / widget.size.height,
                  );
                  final scaledArea = Rect.fromLTRB(
                    area.left * scale,
                    area.top * scale,
                    area.right * scale,
                    area.bottom * scale,
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
                            onPointerDown: (event) {
                              if (activePointer != null ||
                                  event.buttons != kPrimaryButton) {
                                return;
                              }
                              activePointer = event.pointer;
                              start(event.localPosition, scale);
                            },
                            onPointerMove: (event) {
                              if (activePointer == event.pointer) {
                                move(event.localPosition, scale);
                              }
                            },
                            onPointerUp: (event) {
                              if (activePointer == event.pointer) {
                                activePointer = null;
                              }
                            },
                            onPointerCancel: (event) {
                              if (activePointer != event.pointer) return;
                              if (previous != null) {
                                setState(() => area = previous!);
                              }
                              if (!editedRows) rows.text = suggestedRows;
                              activePointer = null;
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(widget.bytes, fit: BoxFit.fill),
                                CustomPaint(
                                  painter: _PaperAreaPainter(
                                    scaledArea,
                                    layout == null ? 0 : count,
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
              ),
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
  const _PaperAreaPainter(this.area, this.rows);
  final Rect area;
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = const Color(0xff294e1a)
      ..strokeWidth = 1.5;
    final marker = Paint()..color = const Color(0xffa8ed53);
    canvas.drawRect(area, Paint()..color = const Color(0x28a8ed53));
    canvas.drawRect(area, border..style = PaintingStyle.stroke);
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
      area != oldDelegate.area || rows != oldDelegate.rows;
}
