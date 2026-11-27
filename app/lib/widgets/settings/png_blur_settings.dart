import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/png_blur.dart';
import '../../models/upload.dart';
import 'settings_fields.dart';

class PngBlurSettings extends StatefulWidget {
  const PngBlurSettings({super.key, required this.fields, this.background});
  final SettingsFields fields;
  final Upload? background;

  @override
  State<PngBlurSettings> createState() => _PngBlurSettingsState();
}

class _PngBlurSettingsState extends State<PngBlurSettings> {
  bool start = true;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final fields = widget.fields;
    final blur = fields.settings.pngBlur;
    final anchor = start ? blur.from : blur.to;
    final labels = {
      PngBlurMode.off: l.pngBlurOff,
      PngBlurMode.uniform: l.pngBlurUniform,
      PngBlurMode.gradient: l.pngBlurGradient,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.pngBlurHint),
        Wrap(
          spacing: 6,
          children: [
            for (final mode in labels.keys)
              ChoiceChip(
                key: ValueKey('png-blur-${mode.name}'),
                label: Text(labels[mode]!),
                selected: blur.mode == mode,
                onSelected: fields.edited((_) => blur.mode = mode),
              ),
          ],
        ),
        if (blur.mode == PngBlurMode.gradient) ...[
          const SizedBox(height: 8),
          Text(l.pngBlurTap),
          Wrap(
            spacing: 6,
            children: [
              for (final first in [true, false])
                ChoiceChip(
                  label: Text(first ? l.pngBlurFrom : l.pngBlurTo),
                  selected: first == start,
                  onSelected: (_) => setState(() => start = first),
                ),
            ],
          ),
          _map(blur, anchor),
          _slider(l.pngBlurX, anchor.x, (v) => anchor.x = v),
          _slider(l.pngBlurY, anchor.y, (v) => anchor.y = v),
          if (!blur.valid)
            Text(
              l.pngBlurDistinct,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
        if (blur.mode != PngBlurMode.off)
          _slider(
            l.pngBlurStrength,
            blur.mode == PngBlurMode.uniform ? blur.uniform : anchor.sigma,
            (v) {
              if (blur.mode == PngBlurMode.uniform) {
                blur.uniform = v;
              } else {
                anchor.sigma = v;
              }
            },
            strength: true,
          ),
        if (blur.active)
          Text(l.pngBlurFineHint, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> change, {
    bool strength = false,
  }) {
    String format(double v) =>
        strength ? '${v.toStringAsFixed(1)} px' : '${(v * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$label · ${format(value)}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        Semantics(
          label: label,
          child: Slider(
            value: value,
            max: strength ? 2 : 1,
            divisions: strength ? 20 : 100,
            label: format(value),
            semanticFormatterCallback: format,
            onChanged: widget.fields.edited(change),
          ),
        ),
      ],
    );
  }

  Widget _map(PngBlur blur, BlurAnchor active) {
    final colors = Theme.of(context).colorScheme;
    final photo = widget.background;
    final values = widget.fields.settings.values;
    final width = double.tryParse(values['width'] ?? '') ?? 1;
    final height = double.tryParse(values['height'] ?? '') ?? 1;
    final paper = photo != null
        ? Image.memory(photo.bytes, fit: BoxFit.contain)
        : AspectRatio(
            aspectRatio: width > 0 && height > 0 && (width / height).isFinite
                ? width / height
                : .75,
            child: ColoredBox(color: colors.surface),
          );
    return Container(
      height: 142,
      color: colors.surfaceContainerLow,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: Stack(
        alignment: Alignment.center,
        children: [
          paper,
          Positioned.fill(
            child: LayoutBuilder(
              builder: (_, surface) {
                return GestureDetector(
                  key: const ValueKey('png-blur-page'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: widget.fields.locked
                      ? null
                      : (event) {
                          double percent(double position, double span) =>
                              (100 * position / span).round().clamp(0, 100) /
                              100;
                          active.x = percent(
                            event.localPosition.dx,
                            surface.maxWidth,
                          );
                          active.y = percent(
                            event.localPosition.dy,
                            surface.maxHeight,
                          );
                          widget.fields.onEdited();
                        },
                  child: CustomPaint(
                    painter: _AnchorPainter(
                      Offset(blur.from.x, blur.from.y),
                      Offset(blur.to.x, blur.to.y),
                      start,
                      colors,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AnchorPainter extends CustomPainter {
  const _AnchorPainter(this.from, this.to, this.start, this.colors);
  final Offset from, to;
  final bool start;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    Offset position(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    final a = position(from), b = position(to);
    final paint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2;
    canvas.drawLine(a, b, paint);
    void mark(Offset point, String label, bool selected) {
      final r = math.min(9.0, size.shortestSide / 2);
      final center = Offset(
        point.dx.clamp(r, size.width - r),
        point.dy.clamp(r, size.height - r),
      );
      paint.color = selected ? colors.primary : colors.secondaryContainer;
      canvas.drawCircle(center, r, paint);
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: r * 1.4,
            color: selected ? colors.onPrimary : colors.onSecondaryContainer,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
    }

    mark(a, 'A', start);
    mark(b, 'B', !start);
  }

  @override
  bool shouldRepaint(_AnchorPainter old) =>
      old.from != from ||
      old.to != to ||
      old.start != start ||
      old.colors != colors;
}
