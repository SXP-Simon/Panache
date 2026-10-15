import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';

/// The repository stays visible in the application header on every screen.
class ProjectSourceLink extends StatelessWidget {
  const ProjectSourceLink({super.key});

  static final uri = Uri.parse('https://github.com/SXP-Simon/handwriting-web');

  @override
  Widget build(BuildContext context) => Tooltip(
    message: AppLocalizations.of(context)!.project,
    child: TextButton.icon(
      key: const ValueKey('project-source-link'),
      onPressed: () => launchUrl(uri),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      icon: ExcludeSemantics(
        child: CustomPaint(
          size: const Size.square(18),
          painter: _GitHubMark(Theme.of(context).colorScheme.primary),
        ),
      ),
      label: const Text(
        'SXP-Simon/handwriting-web',
        style: TextStyle(fontSize: 13),
      ),
    ),
  );
}

/// GitHub outline, following the existing outlined Material icon treatment.
class _GitHubMark extends CustomPainter {
  const _GitHubMark(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(9, 19)
      ..cubicTo(4.7, 20.3, 4.7, 16.5, 3, 16)
      ..moveTo(15, 22)
      ..lineTo(15, 18.1)
      ..cubicTo(15.04, 17.02, 14.67, 16.52, 14.5, 16.2)
      ..cubicTo(17.8, 15.83, 21.3, 14.58, 21.3, 8.8)
      ..cubicTo(21.3, 7.16, 20.71, 5.81, 19.75, 4.76)
      ..cubicTo(19.91, 4.38, 20.42, 2.84, 19.6, 0.76)
      ..cubicTo(19.6, 0.76, 18.34, 0.36, 15.47, 2.3)
      ..cubicTo(13.08, 1.65, 10.56, 1.65, 8.17, 2.3)
      ..cubicTo(5.3, 0.36, 4.04, 0.76, 4.04, 0.76)
      ..cubicTo(3.22, 2.84, 3.73, 4.38, 3.89, 4.76)
      ..cubicTo(2.93, 5.81, 2.34, 7.16, 2.34, 8.8)
      ..cubicTo(2.34, 14.57, 5.83, 15.84, 9.12, 16.2)
      ..cubicTo(8.7, 16.64, 8.47, 17.24, 8.5, 18.1)
      ..lineTo(8.5, 22);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GitHubMark oldDelegate) => oldDelegate.color != color;
}
