import 'dart:ui';

import '../models/fine_edit.dart';
import '../utils/fine_raster.dart';

enum FineTool { select, box, move, pan }

class FineSelection {
  final selected = <int>{};
  FineTool tool = FineTool.select;
  bool snap = true;

  FineGlyph? hit(FinePage page, Map<int, FineAdjustment> edits, Offset point) {
    for (final glyph in page.glyphs.reversed) {
      if (FinePose(glyph, edits[glyph.id]).bounds.contains(point)) return glyph;
    }
    return null;
  }

  void select(Iterable<int> ids, {bool append = false}) {
    if (!append) selected.clear();
    for (final id in ids) {
      if (!append || !selected.remove(id)) selected.add(id);
    }
  }

  void box(
    FinePage page,
    Map<int, FineAdjustment> edits,
    Rect rect, {
    required bool append,
  }) => select(
    page.glyphs
        .where(
          (glyph) => rect.contains(FinePose(glyph, edits[glyph.id]).center),
        )
        .map((glyph) => glyph.id),
    append: append,
  );

  Rect? bounds(FinePage page, Map<int, FineAdjustment> edits) {
    Rect? group;
    for (final glyph in page.glyphs.where(
      (glyph) => selected.contains(glyph.id),
    )) {
      final rect = FinePose(glyph, edits[glyph.id]).bounds;
      group = group?.expandToInclude(rect) ?? rect;
    }
    return group;
  }

  List<FineAdjustment> move(
    FinePage page,
    Map<int, FineAdjustment> edits,
    Offset delta,
    Size size, {
    required bool snapToLine,
  }) {
    final group = bounds(page, edits);
    if (group == null) return [];
    var dy = delta.dy;
    if (snap && snapToLine && dy != 0) {
      final first = page.glyphs.firstWhere(
        (glyph) => selected.contains(glyph.id),
      );
      final baseline = first.baseline + (edits[first.id]?.dy ?? 0);
      final target = baseline + dy;
      var closest = first.baseline;
      for (final glyph in page.glyphs) {
        if ((glyph.baseline - target).abs() < (closest - target).abs()) {
          closest = glyph.baseline;
        }
      }
      if ((closest - target).abs() <= (first.height / 4).clamp(3, 12)) {
        dy = (closest - baseline).toDouble();
      }
    }
    final x = delta.dx
        .clamp(
          (-group.left).clamp(double.negativeInfinity, 0),
          (size.width - group.right).clamp(0, double.infinity),
        )
        .round();
    final y = dy
        .clamp(
          (-group.top).clamp(double.negativeInfinity, 0),
          (size.height - group.bottom).clamp(0, double.infinity),
        )
        .round();
    return change(
      edits,
      (v) => (
        id: v.id,
        dx: (v.dx + x).clamp(-65535, 65535),
        dy: (v.dy + y).clamp(-65535, 65535),
        scale: v.scale,
        angle: v.angle,
        opacity: v.opacity,
        color: v.color,
      ),
    );
  }

  List<FineAdjustment> change(
    Map<int, FineAdjustment> edits,
    FineAdjustment Function(FineAdjustment) update,
  ) => [
    for (final id in selected) update(edits[id] ?? defaultFineAdjustment(id)),
  ];
}
