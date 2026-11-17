import 'dart:math' as math;
import 'dart:ui';

/// Edges in original background pixels. The top and bottom are writing lines.
Map<String, String>? paperAreaLayout(Rect area, Size image, int rows) {
  if (rows < 2 || rows > 500) return null;
  final spacing = (area.height / (rows - 1)).round();
  final first = area.top.round();
  final last = first + spacing * (rows - 1);
  final top = first - spacing;
  if (spacing < 8 ||
      top < 0 ||
      last >= image.height ||
      area.width.round() < 8) {
    return null;
  }
  return {
    'left_margin': '${area.left.round()}',
    'right_margin': '${image.width.round() - area.right.round()}',
    'top_margin': '$top',
    'bottom_margin':
        '${math.max(0, image.height.round() - last - (spacing / 4).ceil())}',
    'line_spacing': '$spacing',
    'width': '${image.width.round()}',
    'height': '${image.height.round()}',
  };
}
