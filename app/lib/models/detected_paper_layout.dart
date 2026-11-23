/// Writing lines and margins in the detector's pixel coordinates.
class DetectedPaperLayout {
  const DetectedPaperLayout._({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.spacing,
    required this.size,
  });

  final int left, right, top, bottom, spacing;
  final ({int width, int height})? size;

  factory DetectedPaperLayout.fromJson(Map<String, dynamic> result) {
    int number(String key, {int? fallback, bool positive = false}) {
      final value = result[key] ?? fallback;
      if (value is! num ||
          !value.isFinite ||
          value < (positive ? 1 : 0) ||
          value > 100000) {
        throw const FormatException('Invalid paper identification');
      }
      return value.round();
    }

    final spacing = number('lineSpacing', positive: true);
    final first = number('marginTop');
    final top = number(
      'layoutTopMargin',
      fallback: first >= spacing ? first - spacing : first,
    );
    final bottom = number(
      'layoutBottomMargin',
      fallback: number('marginBottom'),
    );
    final left = number('marginLeft');
    final right = number('marginRight');
    final width = result.containsKey('imageWidth')
        ? number('imageWidth', positive: true)
        : null;
    final height = result.containsKey('imageHeight')
        ? number('imageHeight', positive: true)
        : null;
    if ((width == null) != (height == null) ||
        (width != null &&
            height != null &&
            (left + right >= width || top + bottom + spacing >= height))) {
      throw const FormatException('Invalid paper dimensions');
    }
    return DetectedPaperLayout._(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      spacing: spacing,
      size: width != null && height != null
          ? (width: width, height: height)
          : null,
    );
  }

  /// A corrected image can be downsampled independently on each axis.
  DetectedPaperLayout scaledTo(int width, int height) {
    final original = size!;
    if (width == original.width && height == original.height) return this;
    final horizontal = width / original.width;
    final vertical = height / original.height;
    return DetectedPaperLayout._(
      left: (left * horizontal).round(),
      right: (right * horizontal).round(),
      top: (top * vertical).round(),
      bottom: (bottom * vertical).round(),
      spacing: (spacing * vertical).round().clamp(1, height),
      size: (width: width, height: height),
    );
  }

  Map<String, String> settings(String? currentFontSize) {
    final fontSize = num.tryParse(currentFontSize ?? '');
    return {
      if (fontSize != null && fontSize >= spacing)
        'font_size': '${(spacing * 0.72).round().clamp(1, 100000)}',
      'left_margin': '$left',
      'right_margin': '$right',
      'top_margin': '$top',
      'bottom_margin': '$bottom',
      'line_spacing': '$spacing',
      if (size case final dimensions?) ...{
        'width': '${dimensions.width}',
        'height': '${dimensions.height}',
      },
    };
  }
}
