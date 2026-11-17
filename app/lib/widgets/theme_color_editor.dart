import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/handwriting_theme.dart';
import 'color_picker_dialog.dart';

/// The sheet keeps an editable snapshot while the parent applies the app theme.
class ThemeColorEditor extends StatefulWidget {
  const ThemeColorEditor({
    super.key,
    required this.color,
    required this.secondaryColor,
    required this.onChanged,
    required this.onSecondaryChanged,
  });

  final Color color, secondaryColor;
  final Future<bool> Function(Color) onChanged, onSecondaryChanged;

  @override
  State<ThemeColorEditor> createState() => _ThemeColorEditorState();
}

class _ThemeColorEditorState extends State<ThemeColorEditor> {
  late Color primary = widget.color;
  late Color secondary = widget.secondaryColor;
  bool primarySaveFailed = false;
  bool secondarySaveFailed = false;

  Future<void> pick({required bool isPrimary, required String title}) async {
    final l = AppLocalizations.of(context)!;
    final chosen = await showDialog<Color>(
      context: context,
      builder: (_) => ColorPickerDialog(
        id: isPrimary ? 'primary-theme-color' : 'secondary-theme-color',
        title: title,
        color: isPrimary ? primary : secondary,
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
    setState(() {
      if (isPrimary) {
        primary = chosen;
        primarySaveFailed = false;
      } else {
        secondary = chosen;
        secondarySaveFailed = false;
      }
    });
    final saved = await (isPrimary
        ? widget.onChanged
        : widget.onSecondaryChanged)(chosen);
    if (!mounted) return;
    setState(() {
      if (isPrimary && primary == chosen) primarySaveFailed = !saved;
      if (!isPrimary && secondary == chosen) secondarySaveFailed = !saved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Card.filled(
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(l.themeColor, style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(l.themeColorHint, style: theme.textTheme.bodySmall),
              ),
              const SizedBox(height: 8),
              for (final (isPrimary, title, hint, color, failed) in [
                (
                  true,
                  l.primaryThemeColor,
                  l.primaryThemeColorHint,
                  primary,
                  primarySaveFailed,
                ),
                (
                  false,
                  l.secondaryThemeColor,
                  l.secondaryThemeColorHint,
                  secondary,
                  secondarySaveFailed,
                ),
              ]) ...[
                ListTile(
                  key: ValueKey(
                    isPrimary
                        ? 'pick-primary-theme-color'
                        : 'pick-secondary-theme-color',
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  title: Text(title),
                  subtitle: Text(hint),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ColorSwatchIndicator(color),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, size: 16),
                    ],
                  ),
                  onTap: () => pick(isPrimary: isPrimary, title: title),
                ),
                if (failed)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      l.themeColorSaveFailed,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
