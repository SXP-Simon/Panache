import 'dart:math' as math;
import 'dart:ui';

/// Edges in original background pixels. The top and bottom are writing lines.
Map<String, String>? paperAreaLayout(
  Rect area,
  Size image,
  int rows, {
  bool enclosed = false,
}) {
  if (rows < 2 || rows > 500) return null;
  final spacing = enclosed
      ? ((area.bottom.floor() - area.top.ceil()) / (rows + .25)).floor()
      : (area.height / (rows - 1)).round();
  final top = enclosed ? area.top.ceil() : area.top.round() - spacing;
  final last = top + spacing * rows;
  final left = enclosed ? area.left.ceil() : area.left.round();
  final right = enclosed ? area.right.floor() : area.right.round();
  if (spacing < 8 || top < 0 || last >= image.height || right - left < 8) {
    return null;
  }
  return {
    'left_margin': '$left',
    'right_margin': '${image.width.round() - right}',
    'top_margin': '$top',
    'bottom_margin':
        '${math.max(0, image.height.round() - last - (spacing / 4).ceil())}',
    'line_spacing': '$spacing',
    'width': '${image.width.round()}',
    'height': '${image.height.round()}',
  };
}
