import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class NouveauColors {
  static const forest = Color(0xFF2D5016);
  static const leaf = Color(0xFF4A7C3F);
  static const ivory = Color(0xFFF5F0E1);
  static const softIvory = Color(0xFFFAF7EF);
  static const gold = Color(0xFFC9A227);
  static const wisteria = Color(0xFF8B6DB5);
  static const nightSage = Color(0xFFBDCAAB);
  static const moonIris = Color(0xFFC8BAFF);
  static const night = Color(0xFF10131D);
}

class NouveauWaveDivider extends StatelessWidget {
  const NouveauWaveDivider({super.key, this.height = 20, this.blossom = false});

  final double height;
  final bool blossom;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _WavePainter(
          Theme.of(context).colorScheme.outlineVariant,
          Theme.of(context).colorScheme.secondary,
          blossom,
        ),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.gold, this.petal, this.blossom);
  final Color gold, petal;
  final bool blossom;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final amplitude = math.min(8.0, mid * .65);
    final wave = Path()..moveTo(0, mid);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (double x = 0; x < size.width; x += 120) {
      wave.cubicTo(
        x + 20,
        mid - amplitude * 1.33,
        x + 40,
        mid - amplitude * 1.33,
        x + 60,
        mid,
      );
      wave.cubicTo(
        x + 80,
        mid + amplitude * 1.33,
        x + 100,
        mid + amplitude * 1.33,
        x + 120,
        mid,
      );
    }
    canvas.drawPath(
      wave,
      Paint()
        ..color = gold
        ..style = PaintingStyle.stroke,
    );
    if (blossom) {
      canvas.translate(size.width / 2, mid);
      final radius = math.min(8.0, mid);
      final brush = Paint()..color = petal;
      for (int i = 0; i < 5; i++) {
        canvas.drawOval(
          Rect.fromLTRB(-radius * .32, -radius, radius * .32, 0),
          brush,
        );
        canvas.rotate(math.pi * 2 / 5);
      }
      canvas.drawCircle(Offset.zero, radius * .24, Paint()..color = gold);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      gold != old.gold || petal != old.petal || blossom != old.blossom;
}

/// Two tapering leaves and a curved stem enclose the panel's functional icon.
class NouveauIconSeal extends StatelessWidget {
  const NouveauIconSeal(this.icon, {super.key});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 36,
      child: CustomPaint(
        painter: _SealPainter(colors.secondaryContainer, colors.secondary),
        child: Center(
          child: Icon(icon, size: 17, color: colors.onSecondaryContainer),
        ),
      ),
    );
  }
}

class _SealPainter extends CustomPainter {
  const _SealPainter(this.fill, this.ink);
  final Color fill, ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 36, size.height / 36);
    final brush = Paint()..color = fill;
    canvas.drawOval(const Rect.fromLTRB(3, 1, 33, 34), brush);
    brush
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    canvas.drawPath(
      Path()
        ..moveTo(3, 10)
        ..cubicTo(-1, 19, 5, 31, 17, 33)
        ..cubicTo(24, 34, 33, 30, 35, 23),
      brush,
    );
    brush.style = PaintingStyle.fill;
    canvas.drawPath(
      Path()
        ..moveTo(7, 28)
        ..quadraticBezierTo(0, 28, 0, 21)
        ..quadraticBezierTo(6, 22, 7, 28)
        ..close()
        ..moveTo(29, 30)
        ..quadraticBezierTo(29, 24, 33, 22)
        ..quadraticBezierTo(34, 27, 29, 30)
        ..close(),
      brush,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SealPainter old) => old.fill != fill || old.ink != ink;
}
