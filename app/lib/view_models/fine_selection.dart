import 'dart:ui';

import '../models/fine_edit.dart';
import '../models/fine_transform.dart';
import '../utils/lasso.dart';
import '../utils/fine_raster.dart';

enum FineTool { select, box, lasso, move, perspective, pan }

typedef FinePerspectiveChange = ({
  List<Offset> points,
  List<FineAdjustment> changes,
});

class FinePerspectiveFrame {
  FinePerspectiveFrame(this.points, this.edits);
  final List<Offset> points;
  final Map<int, FineAdjustment?> edits;

  bool matches(Set<int> selected, Map<int, FineAdjustment> next) =>
      edits.length == selected.length &&
      selected.every((id) {
        if (!edits.containsKey(id)) return false;
        final previous = edits[id] ?? defaultFineAdjustment(id);
        final current = next[id] ?? defaultFineAdjustment(id);
        return previous.dx == current.dx &&
            previous.dy == current.dy &&
            previous.scale == current.scale &&
            previous.angle == current.angle &&
            previous.warp == current.warp;
      });
}

class FineSelection {
  final selected = <int>{};
  FineTool tool = FineTool.select;
  bool snap = true;
  final _perspectiveFrames = <FinePerspectiveFrame>[];

  FineGlyph? hit(FinePage page, Map<int, FineAdjustment> edits, Offset point) {
    for (final glyph in page.glyphs.reversed) {
      if (FinePose(glyph, edits[glyph.id]).hit(glyph, point)) return glyph;
    }
    return null;
  }

  void select(Iterable<int> ids, {bool append = false}) {
    if (!append) selected.clear();
    for (final id in ids) {
      if (!append || !selected.remove(id)) selected.add(id);
    }
  }

  void selectSource(FinePage page, FineRange range) {
    if (!page.glyphs.any((glyph) => glyph.source != null)) return;
    select(
      page.glyphs
          .where((glyph) {
            final span = glyph.source;
            return span != null &&
                span.start < range.end &&
                span.end > range.start;
          })
          .map((glyph) => glyph.id),
    );
  }

  void selectIllustration(FinePage page, int group) => select(
    page.glyphs
        .where((glyph) => glyph.illustrationId == group)
        .map((glyph) => glyph.id),
  );

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

  void lasso(
    FinePage page,
    Map<int, FineAdjustment> edits,
    List<Offset> path, {
    required bool append,
  }) => select(
    page.glyphs
        .where(
          (glyph) =>
              lassoContains(path, FinePose(glyph, edits[glyph.id]).center),
        )
        .map((glyph) => glyph.id),
    append: append,
  );

  List<FineAdjustment>? transform(
    FinePage page,
    Map<int, FineAdjustment> edits, {
    int angle = 0,
    int horizontal = 0,
    int vertical = 0,
  }) {
    final group = bounds(page, edits);
    if (group == null || (angle == 0 && horizontal == 0 && vertical == 0)) {
      return [];
    }
    final gx = 2 * horizontal / (100 * group.width.clamp(1, double.infinity));
    final gy = 2 * vertical / (100 * group.height.clamp(1, double.infinity));
    return _project(
      page,
      edits,
      (edit, pose) => transformFineWarp(
        edit.warp,
        pose.origin - group.center,
        angle,
        gx,
        gy,
      ),
    );
  }

  FinePerspectiveFrame? perspectiveFrame(
    FinePage page,
    Map<int, FineAdjustment> edits,
  ) {
    for (final frame in _perspectiveFrames) {
      if (frame.matches(selected, edits)) return frame;
    }
    final box = bounds(page, edits);
    if (box == null) return null;
    return FinePerspectiveFrame(
      [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft],
      {for (final id in selected) id: edits[id]},
    );
  }

  FinePerspectiveChange? corner(
    FinePage page,
    Map<int, FineAdjustment> edits,
    FinePerspectiveFrame frame,
    int index,
    Offset delta,
    Size size,
  ) {
    final anchor = frame.points[index];
    double limit(double value, double previous, double extent) => value.clamp(
      previous.clamp(double.negativeInfinity, 0),
      previous.clamp(extent, double.infinity),
    );
    final target = Offset(
      limit(anchor.dx + delta.dx, anchor.dx, size.width),
      limit(anchor.dy + delta.dy, anchor.dy, size.height),
    );
    if ((target - anchor).distance < 1e-6) {
      return (points: frame.points, changes: []);
    }
    final points = [...frame.points]..[index] = target;
    final map = fineQuadTransform(frame.points, points);
    if (map == null) return null;
    final changes = _project(
      page,
      edits,
      (edit, pose) =>
          composeFineWarp(edit.warp, pose.origin - map.origin, map.matrix),
    );
    return changes == null ? null : (points: points, changes: changes);
  }

  void rememberCorner(
    FinePerspectiveFrame previous,
    FinePerspectiveChange result,
  ) {
    _perspectiveFrames
      ..remove(previous)
      ..insertAll(0, [
        FinePerspectiveFrame(result.points, {
          for (final edit in result.changes) edit.id: edit,
        }),
        previous,
      ]);
    if (_perspectiveFrames.length > 50) {
      _perspectiveFrames.removeRange(50, _perspectiveFrames.length);
    }
  }

  List<FineAdjustment>? _project(
    FinePage page,
    Map<int, FineAdjustment> edits,
    FineWarp Function(FineAdjustment, FinePose) map,
  ) {
    final result = <FineAdjustment>[];
    for (final glyph in page.glyphs.where(
      (glyph) => selected.contains(glyph.id),
    )) {
      final edit = edits[glyph.id] ?? defaultFineAdjustment(glyph.id);
      final pose = FinePose(glyph, edit);
      final warp = map(edit, pose);
      if (!fineWarpFits(
        warp,
        fineCorners(glyph.width, glyph.height, pose.scale, pose.cos, pose.sin),
      )) {
        return null;
      }
      result.add((
        id: edit.id,
        dx: edit.dx,
        dy: edit.dy,
        scale: edit.scale,
        angle: edit.angle,
        opacity: edit.opacity,
        color: edit.color,
        thickness: edit.thickness,
        softness: edit.softness,
        warp: warp,
      ));
    }
    return result;
  }

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
        thickness: v.thickness,
        softness: v.softness,
        warp: v.warp,
      ),
    );
  }

  List<FineAdjustment> adjust(
    Map<int, FineAdjustment> edits, {
    int? scale,
    int? angle,
    int? opacity,
    int? color,
    int? thickness,
    int? softness,
  }) => change(
    edits,
    (v) => (
      id: v.id,
      dx: v.dx,
      dy: v.dy,
      scale: scale ?? v.scale,
      angle: angle ?? v.angle,
      opacity: opacity ?? v.opacity,
      color: color ?? v.color,
      thickness: thickness ?? v.thickness,
      softness: softness ?? v.softness,
      warp: v.warp,
    ),
  );

  List<FineAdjustment> change(
    Map<int, FineAdjustment> edits,
    FineAdjustment Function(FineAdjustment) update,
  ) => [
    for (final id in selected) update(edits[id] ?? defaultFineAdjustment(id)),
  ];
}
