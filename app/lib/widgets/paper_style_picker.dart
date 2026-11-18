import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/settings.dart';

class PaperStylePicker extends StatelessWidget {
  const PaperStylePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final PaperStyle value;
  final ValueChanged<PaperStyle>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 6.0;
        final columns =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(240) ? 4 : 2;
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (style, label) in [
              (PaperStyle.blank, l.paperBlank),
              (PaperStyle.ruled, l.paperRuled),
              (PaperStyle.grid, l.paperGrid),
              (PaperStyle.dots, l.paperDots),
            ])
              SizedBox(
                width: width,
                child: Semantics(
                  selected: style == value,
                  child: OutlinedButton(
                    key: ValueKey('paper-style-${style.name}'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: style == value
                          ? colors.secondaryContainer
                          : null,
                      foregroundColor: style == value
                          ? colors.onSecondaryContainer
                          : colors.onSurface,
                      side: BorderSide(
                        color: style == value
                            ? colors.secondary
                            : colors.outlineVariant,
                      ),
                      padding: const EdgeInsets.all(5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: onChanged == null
                        ? null
                        : () => onChanged!(style),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            height: 25,
                            width: double.infinity,
                            child: CustomPaint(painter: _Swatch(style)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Swatch extends CustomPainter {
  const _Swatch(this.style);
  final PaperStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final rule = Paint()
      ..color = const Color(0xffa2aab4)
      ..strokeWidth = 0.75;
    const spacing = 6.0;
    for (var y = spacing; y < size.height; y += spacing) {
      if (style == PaperStyle.ruled || style == PaperStyle.grid) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), rule);
      } else if (style == PaperStyle.dots) {
        for (var x = spacing; x < size.width; x += spacing) {
          canvas.drawCircle(Offset(x, y), 0.85, rule);
        }
      }
    }
    if (style == PaperStyle.grid) {
      for (var x = spacing; x < size.width; x += spacing) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), rule);
      }
    }
  }

  @override
  bool shouldRepaint(_Swatch oldDelegate) => oldDelegate.style != style;
}
