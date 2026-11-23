import 'dart:ui';

import '../models/fine_edit.dart';
import '../utils/lasso.dart';
import 'fine_selection.dart';

enum FineDragAction { tap, move, box, lasso }

/// A primary pointer keeps the tool and hit from the moment it touches the page.
/// Hit testing and outlines use paper coordinates. Drag slop uses screen pixels.
class FineSelectionDrag {
  FineSelectionDrag._(
    this.pointer,
    this.start,
    this._screen,
    this._hit,
    this._append,
    this.action,
  ) : _path = action == FineDragAction.lasso ? [start] : null;

  factory FineSelectionDrag.begin(
    FineSelection selection,
    FinePage page,
    Map<int, FineAdjustment> edits, {
    required int pointer,
    required Offset start,
    required Offset screen,
    required bool touch,
    required bool shift,
  }) {
    final hit = selection.hit(page, edits, start);
    final append = !touch && shift;
    final group = selection.bounds(page, edits);
    final inSelection =
        group != null &&
        group.contains(start) &&
        (hit == null || selection.selected.contains(hit.id));
    final action = switch (selection.tool) {
      FineTool.move => FineDragAction.move,
      FineTool.select when touch => FineDragAction.tap,
      FineTool.select when !append && (inSelection || hit != null) =>
        FineDragAction.move,
      FineTool.lasso => FineDragAction.lasso,
      _ => FineDragAction.box,
    };
    return FineSelectionDrag._(pointer, start, screen, hit, append, action);
  }

  final int pointer;
  final Offset start, _screen;
  final FineGlyph? _hit;
  final bool _append;
  final FineDragAction action;
  final List<Offset>? _path;
  bool moved = false;
  Rect? box;
  List<Offset> lasso = [];

  bool acceptsMove(int id, Offset screen) =>
      pointer == id && (moved || (screen - _screen).distance >= 4);

  bool selectMoveTarget(FineSelection selection, {required bool mouse}) {
    final hit = _hit;
    if (moved ||
        action != FineDragAction.move ||
        !mouse ||
        hit == null ||
        selection.selected.contains(hit.id))
      return false;
    selection.select([hit.id]);
    return true;
  }

  void outline(Offset point, double minimum) {
    final path = _path;
    if (path == null) {
      box = Rect.fromPoints(start, point);
    } else {
      appendLassoPoint(path, point, minimum);
      lasso = [...path, point];
    }
  }

  bool finishSelection(
    FineSelection selection,
    FinePage page,
    Map<int, FineAdjustment> edits,
    Offset point, {
    required bool mouse,
  }) {
    if (!moved) {
      if (!mouse && action == FineDragAction.move) return false;
      selection.select([if (_hit case final hit?) hit.id], append: _append);
      return true;
    }
    switch (action) {
      case FineDragAction.lasso:
        selection.lasso(page, edits, [..._path!, point], append: _append);
      case FineDragAction.box:
        selection.box(
          page,
          edits,
          Rect.fromPoints(start, point),
          append: _append,
        );
      case FineDragAction.tap:
      case FineDragAction.move:
        return false;
    }
    return true;
  }
}

/// A perspective drag retains the original frame even as its live outline moves.
class FineCornerDrag {
  FineCornerDrag._(this.pointer, this.index, this.start, this.frame);
  final int pointer, index;
  final Offset start;
  final FinePerspectiveFrame frame;
  FinePerspectiveChange? latest;

  static FineCornerDrag? hit(
    int pointer,
    Offset at,
    FinePerspectiveFrame? frame,
    double radius,
  ) {
    if (frame == null) return null;
    var nearest = radius;
    int? index;
    for (final (i, point) in frame.points.indexed) {
      final distance = (at - point).distance;
      if (distance <= nearest) {
        nearest = distance;
        index = i;
      }
    }
    return index == null ? null : FineCornerDrag._(pointer, index, at, frame);
  }

  FinePerspectiveChange? project(
    FineSelection selection,
    FinePage page,
    Map<int, FineAdjustment> edits,
    Offset point,
    Size size,
  ) => selection.corner(page, edits, frame, index, point - start, size);
}
