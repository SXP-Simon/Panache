import 'package:flutter/material.dart';

import 'atelier_ornament.dart';

/// A stationery vignette drawn in the two inks of the current palette.
class IrisQuill extends StatelessWidget {
  const IrisQuill({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: height,
      child: FittedBox(
        child: CustomPaint(
          size: const Size(224, 208),
          painter: _QuillPainter(Theme.of(context).colorScheme),
        ),
      ),
    ),
  );
}

class _QuillPainter extends CustomPainter {
  const _QuillPainter(this.colors);
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = colors.tertiary;
    final paper = Color.lerp(const Color(0xfff3ead6), colors.secondary, .09)!;
    final fold = Color.lerp(paper, ink, .38)!;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void line(Path path, Color color) =>
        canvas.drawPath(path, pen..color = color);
    void shape(Path path, Color fill, Color edge) {
      canvas.drawPath(path, Paint()..color = fill);
      line(path, edge);
    }

    canvas.save();
    canvas.scale(size.width / 224, size.height / 208);
    // The stems meet the inkwell; the flower uses the same engraved petals
    // as the masthead, with the primary ink on the bloom.
    line(
      Path()
        ..moveTo(65, 153)
        ..cubicTo(65, 122, 43, 118, 42, 98),
      colors.secondary,
    );
    canvas.save();
    canvas.translate(17, 5);
    AtelierIris(palette: colors).paint(canvas, const Size(114, 114));
    canvas.restore();

    // A folded right edge gives the sheet a silhouette even on a pale surface.
    shape(
      Path()
        ..moveTo(53, 154)
        ..cubicTo(90, 144, 134, 158, 170, 141)
        ..quadraticBezierTo(183, 136, 193, 143)
        ..quadraticBezierTo(201, 152, 192, 158)
        ..lineTo(174, 161)
        ..cubicTo(164, 177, 168, 191, 142, 195)
        ..cubicTo(114, 200, 92, 180, 55, 185)
        ..close(),
      paper,
      ink,
    );
    shape(
      Path()
        ..moveTo(174, 161)
        ..quadraticBezierTo(182, 138, 193, 143)
        ..quadraticBezierTo(181, 147, 192, 158)
        ..close(),
      fold,
      ink,
    );
    for (int i = 0; i < 3; i++) {
      final y = 163.0 + i * 6;
      line(
        Path()
          ..moveTo(87, y)
          ..cubicTo(103, y - 2, 116, y + 5, 139 - i * 6, y + 1),
        ink.withValues(alpha: .52),
      );
    }

    // Long asymmetrical vanes and two notches form the feather. Their shared
    // curved shaft continues beyond the vane into the ink bottle.
    final featherInk = Color.lerp(colors.secondary, colors.primary, .32)!;
    final vane = Path()
      ..moveTo(78, 125)
      ..cubicTo(84, 102, 98, 84, 120, 73)
      ..lineTo(115, 81)
      ..cubicTo(140, 60, 169, 59, 199, 34)
      ..cubicTo(193, 55, 178, 73, 155, 87)
      ..lineTo(162, 85)
      ..cubicTo(139, 105, 108, 104, 78, 125)
      ..close();
    shape(vane, Color.lerp(paper, featherInk, .23)!, featherInk);
    line(
      Path()
        ..moveTo(61, 153)
        ..cubicTo(82, 115, 106, 99, 140, 83)
        ..quadraticBezierTo(174, 66, 197, 37),
      featherInk,
    );
    final barbs = Path()
      ..moveTo(94, 111)
      ..quadraticBezierTo(97, 100, 104, 90)
      ..moveTo(111, 99)
      ..quadraticBezierTo(120, 87, 130, 78)
      ..moveTo(132, 87)
      ..quadraticBezierTo(145, 75, 155, 70)
      ..moveTo(103, 105)
      ..quadraticBezierTo(120, 105, 135, 97)
      ..moveTo(126, 90)
      ..quadraticBezierTo(143, 89, 156, 81);
    line(barbs, featherInk.withValues(alpha: .62));

    final bottle = Path()
      ..moveTo(50, 148)
      ..lineTo(68, 148)
      ..lineTo(68, 155)
      ..cubicTo(68, 160, 81, 162, 80, 169)
      ..lineTo(77, 179)
      ..quadraticBezierTo(61, 186, 41, 179)
      ..lineTo(39, 169)
      ..cubicTo(38, 162, 50, 161, 50, 155)
      ..close();
    shape(
      bottle,
      Color.lerp(colors.surfaceContainerLow, colors.primary, .55)!,
      ink,
    );
    canvas.drawOval(const Rect.fromLTWH(49, 145, 20, 6), Paint()..color = ink);
    canvas.drawOval(
      const Rect.fromLTWH(52, 146.5, 14, 2.4),
      Paint()..color = colors.surfaceContainerLow,
    );
    line(
      Path()
        ..moveTo(46, 167)
        ..quadraticBezierTo(51, 165, 54, 161)
        ..moveTo(46, 176)
        ..quadraticBezierTo(56, 180, 67, 178),
      paper.withValues(alpha: .7),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QuillPainter oldDelegate) => oldDelegate.colors != colors;
}
