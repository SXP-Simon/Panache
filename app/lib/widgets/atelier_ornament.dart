import 'package:flutter/material.dart';

/// An engraved iris, composed of recurved standards, drooping falls and leaves.
class AtelierIris extends CustomPainter {
  const AtelierIris({this.palette});
  final ColorScheme? palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 104, size.height / 104);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .95
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = palette?.tertiary ?? const Color(0xffe4c76c);
    final fill = Paint();
    void shape(
      Path path,
      int dayColor, {
      required bool petal,
      required double depth,
    }) {
      final colors = palette;
      fill.color = colors == null
          ? Color(dayColor)
          : Color.lerp(
              colors.surfaceContainerLow,
              petal ? colors.primary : colors.secondary,
              depth,
            )!;
      canvas.drawPath(path, fill);
      canvas.drawPath(path, line);
    }

    final halo = Rect.fromLTRB(20, 5, 90, 79);
    canvas.drawOval(halo, line);
    canvas.drawArc(halo.inflate(3), -2.94, 4.47, false, line);
    shape(
      Path()
        ..moveTo(20, 101)
        ..cubicTo(49, 84, 58, 57, 57, 36)
        ..cubicTo(62, 59, 54, 85, 25, 101)
        ..close(),
      0xff678051,
      petal: false,
      depth: .40,
    );
    shape(
      Path()
        ..moveTo(24, 100)
        ..cubicTo(12, 79, 25, 60, 12, 39)
        ..cubicTo(33, 52, 36, 78, 24, 100)
        ..close(),
      0xff73885a,
      petal: false,
      depth: .54,
    );
    shape(
      Path()
        ..moveTo(32, 95)
        ..cubicTo(61, 89, 67, 61, 91, 55)
        ..cubicTo(75, 72, 71, 96, 32, 95)
        ..close(),
      0xff516f45,
      petal: false,
      depth: .28,
    );
    canvas.drawPath(
      Path()
        ..moveTo(23, 96)
        ..quadraticBezierTo(28, 64, 17, 48)
        ..moveTo(36, 93)
        ..quadraticBezierTo(57, 90, 82, 63),
      line,
    );
    // The upright petals and their darker, folded reverses.
    shape(
      Path()
        ..moveTo(56, 44)
        ..cubicTo(40, 42, 29, 24, 35, 17)
        ..cubicTo(39, 14, 43, 22, 48, 20)
        ..cubicTo(54, 24, 53, 35, 56, 44)
        ..close(),
      0xff9e81b0,
      petal: true,
      depth: .60,
    );
    shape(
      Path()
        ..moveTo(56, 42)
        ..cubicTo(48, 28, 43, 11, 54, 9)
        ..cubicTo(60, 7, 60, 14, 65, 14)
        ..cubicTo(72, 17, 64, 32, 56, 42)
        ..close(),
      0xffc4a6c9,
      petal: true,
      depth: .90,
    );
    shape(
      Path()
        ..moveTo(57, 43)
        ..cubicTo(59, 32, 69, 17, 79, 19)
        ..cubicTo(86, 21, 82, 27, 86, 29)
        ..cubicTo(80, 35, 70, 38, 57, 43)
        ..close(),
      0xffa68ab9,
      petal: true,
      depth: .68,
    );
    shape(
      Path()
        ..moveTo(56, 40)
        ..cubicTo(45, 28, 25, 32, 20, 45)
        ..cubicTo(16, 56, 22, 60, 30, 55)
        ..cubicTo(42, 48, 37, 39, 56, 40)
        ..close(),
      0xffb6a0c5,
      petal: true,
      depth: .80,
    );
    shape(
      Path()
        ..moveTo(57, 41)
        ..cubicTo(70, 32, 86, 36, 90, 48)
        ..cubicTo(95, 62, 83, 61, 76, 54)
        ..cubicTo(70, 47, 66, 42, 57, 41)
        ..close(),
      0xffaa8eb9,
      petal: true,
      depth: .70,
    );
    shape(
      Path()
        ..moveTo(54, 38)
        ..cubicTo(43, 40, 41, 56, 45, 62)
        ..cubicTo(47, 67, 53, 65, 56, 61)
        ..cubicTo(66, 55, 65, 45, 60, 39)
        ..close(),
      0xff94749e,
      petal: true,
      depth: .46,
    );
    canvas.drawPath(
      Path()
        ..moveTo(53, 42)
        ..quadraticBezierTo(55, 50, 48, 59)
        ..moveTo(57, 36)
        ..quadraticBezierTo(59, 25, 55, 16)
        ..moveTo(61, 40)
        ..quadraticBezierTo(77, 37, 85, 52)
        ..moveTo(48, 38)
        ..quadraticBezierTo(31, 36, 24, 49),
      line,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(56, 41), width: 8, height: 4),
      fill..color = palette?.onSurface ?? const Color(0xffecd27c),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(AtelierIris oldDelegate) => palette != oldDelegate.palette;
}

/// A pair of whiplash stems filling the negative space in the wide masthead.
class AtelierTendrils extends CustomPainter {
  const AtelierTendrils({this.palette});
  final ColorScheme? palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 340, size.height / 84);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1
      ..color =
          palette?.tertiary.withValues(alpha: .52) ?? const Color(0x99dfc47a);
    canvas.drawPath(
      Path()
        ..moveTo(-6, 86)
        ..cubicTo(69, 83, 75, 16, 153, 17)
        ..cubicTo(209, 16, 211, 73, 170, 65)
        ..cubicTo(143, 59, 155, 30, 171, 39)
        ..cubicTo(178, 44, 173, 51, 170, 49)
        ..moveTo(27, 85)
        ..cubicTo(75, 68, 102, 16, 151, 23)
        ..moveTo(100, 38)
        ..cubicTo(155, 0, 202, 9, 239, 35)
        ..cubicTo(274, 59, 300, 53, 340, 20)
        ..moveTo(212, 21)
        ..cubicTo(251, 26, 260, 8, 285, 6),
      line,
    );
    final blade = Path()
      ..moveTo(0, 0)
      ..cubicTo(8, -13, 20, -13, 31, -16)
      ..cubicTo(25, -5, 15, 2, 0, 0)
      ..close();
    for (final (x, y, angle) in [
      (77.0, 54.0, -.58),
      (98.0, 39.0, -.48),
      (225.0, 22.0, -.38),
      (249.0, 19.0, .12),
      (285.0, 47.0, .05),
      (307.0, 41.0, -.34),
    ]) {
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.drawPath(
        blade,
        Paint()
          ..color =
              palette?.secondary.withValues(alpha: .18) ??
              const Color(0x666f8850),
      );
      canvas.drawPath(blade, line);
      canvas.drawPath(
        Path()
          ..moveTo(3, -1)
          ..quadraticBezierTo(16, -6, 26, -13),
        line,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AtelierTendrils oldDelegate) =>
      palette != oldDelegate.palette;
}

/// A closed iris bud with tapered sword leaves for the foot of the tool rail.
class AtelierBud extends CustomPainter {
  const AtelierBud(this.ink, this.leaf, this.petal);
  final Color ink, leaf, petal;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 96, size.height / 160);
    final outline = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void plate(Path shape, Color color) {
      canvas.drawPath(shape, Paint()..color = color);
      canvas.drawPath(shape, outline);
    }

    plate(
      Path()
        ..moveTo(20, 151)
        ..cubicTo(54, 114, 47, 80, 60, 45)
        ..cubicTo(51, 82, 61, 112, 25, 152)
        ..close(),
      leaf,
    );
    plate(
      Path()
        ..moveTo(23, 148)
        ..cubicTo(36, 118, 10, 89, 15, 58)
        ..cubicTo(18, 78, 47, 105, 29, 139)
        ..close(),
      leaf,
    );
    plate(
      Path()
        ..moveTo(30, 145)
        ..cubicTo(44, 135, 56, 105, 81, 89)
        ..cubicTo(70, 105, 66, 133, 30, 145)
        ..close(),
      leaf,
    );
    plate(
      Path()
        ..moveTo(58, 55)
        ..cubicTo(53, 45, 50, 34, 56, 23)
        ..quadraticBezierTo(61, 14, 65, 10)
        ..cubicTo(70, 23, 73, 39, 58, 55)
        ..close(),
      petal,
    );
    plate(
      Path()
        ..moveTo(57, 56)
        ..cubicTo(52, 50, 50, 43, 51, 37)
        ..quadraticBezierTo(56, 40, 58, 48)
        ..quadraticBezierTo(64, 38, 71, 33)
        ..quadraticBezierTo(67, 47, 57, 56)
        ..close(),
      leaf,
    );
    canvas.drawPath(
      Path()
        ..moveTo(59, 46)
        ..quadraticBezierTo(66, 29, 63, 19)
        ..moveTo(29, 137)
        ..quadraticBezierTo(31, 106, 19, 80)
        ..moveTo(37, 139)
        ..quadraticBezierTo(51, 132, 71, 103)
        ..moveTo(14, 152)
        ..quadraticBezierTo(28, 154, 40, 149),
      outline,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(AtelierBud oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.leaf != leaf ||
      oldDelegate.petal != petal;
}
