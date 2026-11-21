import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'workbench_card.dart';

import '../l10n/app_localizations.dart';
import '../theme/handwriting_theme.dart';
import 'color_picker_dialog.dart';

class ThemeColorEditor extends StatefulWidget {
  const ThemeColorEditor({
    super.key,
    required this.color,
    required this.secondaryColor,
    required this.onPaletteChanged,
  });

  final Color color, secondaryColor;
  final Future<bool> Function(Color, Color)? onPaletteChanged;

  @override
  State<ThemeColorEditor> createState() => _ThemeColorEditorState();
}

class _ThemeColorEditorState extends State<ThemeColorEditor>
    with AutomaticKeepAliveClientMixin {
  // A scrolled-away palette retains its unsaved selection and retry state.
  @override
  bool get wantKeepAlive => true;

  late Color primary = widget.color;
  late Color secondary = widget.secondaryColor;
  bool failed = false;
  int revision = 0;

  Future<void> apply(Color base, Color accent) async {
    final save = widget.onPaletteChanged;
    if (save == null) return;
    final change = ++revision;
    setState(() {
      primary = base;
      secondary = accent;
      failed = false;
    });
    var saved = false;
    try {
      saved = await save(base, accent);
    } catch (_) {
      saved = false;
    }
    if (mounted && change == revision && !saved) {
      setState(() => failed = true);
    }
  }

  Future<void> pick(bool isPrimary, String title) async {
    final l = AppLocalizations.of(context)!;
    final chosen = await showDialog<Color>(
      context: context,
      builder: (_) => ColorPickerDialog(
        id: isPrimary ? 'primary-theme-color' : 'secondary-theme-color',
        title: title,
        color: isPrimary ? primary : secondary,
        previewBuilder: (chosen) => _PaletteProof(
          label: ColorPickerDialog.hexOf(chosen),
          primary: isPrimary ? chosen : primary,
          secondary: isPrimary ? secondary : chosen,
        ),
        presets: [
          (
            l.defaultThemeSwatch,
            isPrimary ? defaultThemeColor : defaultSecondaryThemeColor,
          ),
          (l.blue, const Color(0xFF438FC1)),
          (l.purpleThemeSwatch, const Color(0xFF7955A3)),
          (l.tealThemeSwatch, const Color(0xFF168478)),
        ],
      ),
    );
    if (!mounted || chosen == null) return;
    await apply(isPrimary ? chosen : primary, isPrimary ? secondary : chosen);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final options = [
      ('iris', l.paletteIris, defaultThemeColor, defaultSecondaryThemeColor),
      (
        'celadon',
        l.paletteCeladon,
        const Color(0xff27665d),
        const Color(0xffa28247),
      ),
      (
        'coral',
        l.paletteCoral,
        const Color(0xff924e56),
        const Color(0xff597c70),
      ),
    ];
    final selected = options
        .where((recipe) => recipe.$3 == primary && recipe.$4 == secondary)
        .firstOrNull;
    final editable = widget.onPaletteChanged != null;
    return WorkbenchCard(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.themeColor, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(l.themeColorHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            _PaletteProof(
              label: selected?.$2 ?? l.paletteCustom,
              primary: theme.colorScheme.primary,
              secondary: theme.colorScheme.secondary,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (id, name, base, accent) in options)
                  ChoiceChip(
                    key: ValueKey('palette-$id'),
                    selected: selected?.$1 == id,
                    label: Text(name),
                    avatar: ExcludeSemantics(
                      child: CustomPaint(
                        size: const Size(24, 24),
                        painter: _PaletteFlower(base, accent),
                      ),
                    ),
                    onSelected: editable ? (_) => apply(base, accent) : null,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (final (isPrimary, label, color) in [
              (true, l.primaryThemeColor, primary),
              (false, l.secondaryThemeColor, secondary),
            ])
              ListTile(
                key: ValueKey(
                  isPrimary
                      ? 'pick-primary-theme-color'
                      : 'pick-secondary-theme-color',
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: ColorSwatchIndicator(color),
                title: Text(label),
                subtitle: Text(ColorPickerDialog.hexOf(color)),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: editable ? () => pick(isPrimary, label) : null,
              ),
            if (selected?.$1 != 'iris')
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: editable
                      ? () =>
                            apply(defaultThemeColor, defaultSecondaryThemeColor)
                      : null,
                  icon: const Icon(Icons.restore),
                  label: Text(l.paletteRestore),
                ),
              ),
            if (failed)
              Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.themeColorSaveFailed,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    TextButton(
                      onPressed: () => apply(primary, secondary),
                      child: Text(l.retry),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PaletteProof extends StatelessWidget {
  const _PaletteProof({
    required this.label,
    required this.primary,
    required this.secondary,
  });
  final String label;
  final Color primary, secondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(primary.withValues(alpha: .14), colors.surface),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: colors.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 58,
              height: 64,
              child: CustomPaint(painter: _PaletteFlower(primary, secondary)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A two-ink botanical proof. Both colors come directly from the selection.
class _PaletteFlower extends CustomPainter {
  const _PaletteFlower(this.leaf, this.petals);
  final Color leaf, petals;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 58, size.height / 64);
    final pen = Paint()
      ..color = leaf
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(6, 60)
        ..cubicTo(25, 54, 35, 36, 36, 22),
      pen,
    );
    final brush = Paint()..color = leaf;
    canvas.drawPath(
      Path()
        ..moveTo(19, 53)
        ..quadraticBezierTo(5, 50, 6, 34)
        ..quadraticBezierTo(20, 39, 19, 53)
        ..close()
        ..moveTo(29, 42)
        ..quadraticBezierTo(35, 28, 53, 30)
        ..quadraticBezierTo(44, 43, 29, 42)
        ..close(),
      brush,
    );
    canvas.translate(36, 20);
    brush.color = petals;
    final petal = Path()
      ..moveTo(0, 0)
      ..cubicTo(-8, -4, -8, -14, -2, -16)
      ..cubicTo(5, -19, 8, -7, 0, 0)
      ..close();
    for (var i = 0; i < 5; i++) {
      canvas.drawPath(petal, brush);
      canvas.rotate(math.pi * 2 / 5);
    }
    canvas.drawCircle(Offset.zero, 3.4, brush..color = leaf);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PaletteFlower old) =>
      leaf != old.leaf || petals != old.petals;
}
