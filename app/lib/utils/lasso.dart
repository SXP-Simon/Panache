import 'dart:math' as math;
import 'dart:ui';

bool lassoContains(List<Offset> points, Offset point) {
  if (points.length < 3) return false;
  var inside = false;
  var previous = points.last;
  for (final next in points) {
    if ((next.dy > point.dy) != (previous.dy > point.dy) &&
        point.dx <
            next.dx +
                (point.dy - next.dy) *
                    (previous.dx - next.dx) /
                    (previous.dy - next.dy)) {
      inside = !inside;
    }
    previous = next;
  }
  return inside;
}

void appendLassoPoint(List<Offset> points, Offset point, double minimum) {
  if (points.isEmpty || (points.last - point).distance >= minimum) {
    if (points.length == 2048) {
      for (var i = 0; i < 1024; i++) {
        points[i] = points[i * 2];
      }
      points.removeRange(1024, points.length);
    }
    points.add(point);
  }
}

/// Largest rectangular grid region fully enclosed by the lasso.
Rect? enclosedRectangle(List<Offset> points) {
  if (points.length < 3) return null;
  var bounds = Rect.fromPoints(points.first, points.first);
  for (final point in points.skip(1)) {
    bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
  }
  const cells = 64;
  final dx = bounds.width / cells, dy = bounds.height / cells;
  if (dx <= 0 || dy <= 0) return null;
  final heights = List.filled(cells, 0);
  var best = 0;
  Rect? result;
  for (var row = 0; row < cells; row++) {
    final top = bounds.top + row * dy, bottom = top + dy;
    final y = (top + bottom) / 2;
    final cuts = <double>[];
    final edges = <(double, double)>[];
    var previous = points.last;
    for (final next in points) {
      final run = next.dx - previous.dx, rise = next.dy - previous.dy;
      if ((next.dy > y) != (previous.dy > y)) {
        cuts.add(next.dx + (y - next.dy) * run / rise);
      }
      if (math.min(previous.dy, next.dy) < bottom &&
          math.max(previous.dy, next.dy) > top) {
        final from = rise == 0
            ? 0.0
            : ((top - previous.dy) / rise).clamp(0.0, 1.0);
        final to = rise == 0
            ? 1.0
            : ((bottom - previous.dy) / rise).clamp(0.0, 1.0);
        final a = previous.dx + run * from, b = previous.dx + run * to;
        edges.add((math.min(a, b), math.max(a, b)));
      }
      previous = next;
    }
    cuts.sort();
    var cut = 0;
    for (var column = 0; column < cells; column++) {
      final left = bounds.left + column * dx, right = left + dx;
      while (cut < cuts.length && cuts[cut] <= left) {
        cut++;
      }
      heights[column] =
          cut.isOdd && !edges.any((edge) => edge.$1 < right && edge.$2 > left)
          ? heights[column] + 1
          : 0;
    }
    final stack = <int>[];
    for (var column = 0; column <= cells; column++) {
      final current = column == cells ? 0 : heights[column];
      while (stack.isNotEmpty && heights[stack.last] > current) {
        final height = heights[stack.removeLast()];
        final first = stack.isEmpty ? 0 : stack.last + 1;
        final area = height * (column - first);
        if (area <= best) continue;
        best = area;
        result = Rect.fromLTRB(
          bounds.left + first * dx,
          bottom - height * dy,
          bounds.left + column * dx,
          bottom,
        );
      }
      stack.add(column);
    }
  }
  return result;
}
