import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/handwriting_theme.dart';

/// Edits the interface seed, independently from document rendering settings.
class ThemeColorEditor extends StatefulWidget {
  const ThemeColorEditor({
    super.key,
    required this.color,
    required this.onChanged,
  });
  final Color color;
  final Future<bool> Function(Color) onChanged;
  @override
  State<ThemeColorEditor> createState() => _ThemeColorEditorState();
}

class _ThemeColorEditorState extends State<ThemeColorEditor> {
  late final TextEditingController hex;
  late Color selected;
  bool invalid = false;
  bool saveFailed = false;
  int revision = 0;
  String encode(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  @override
  void initState() {
    super.initState();
    selected = widget.color;
    hex = TextEditingController(text: encode(selected));
  }

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  Future<void> choose(Color color) async {
    final current = ++revision;
    setState(() {
      selected = color;
      hex.text = encode(color);
      invalid = false;
    });
    final saved = await widget.onChanged(color);
    if (mounted && current == revision) setState(() => saveFailed = !saved);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.themeColor, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(l.themeColorHint),
          if (saveFailed)
            Text(
              l.themeColorSaveFailed,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in const [
                defaultThemeColor,
                Color(0xFF2962A3),
                Color(0xFF7955A3),
                Color(0xFFB04A69),
                Color(0xFF99641C),
                Color(0xFF147D79),
              ])
                Semantics(
                  label: encode(color),
                  selected: selected == color,
                  child: IconButton.filledTonal(
                    key: ValueKey('theme-color-${encode(color)}'),
                    tooltip: encode(color),
                    style: IconButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => choose(color),
                    icon: Icon(
                      selected == color ? Icons.check : Icons.circle_outlined,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('theme-color-hex'),
            controller: hex,
            maxLength: 7,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: l.themeColorHex,
              errorText: invalid ? l.themeColorInvalid : null,
              counterText: '',
            ),
            onSubmitted: (_) => apply(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const ValueKey('apply-theme-color'),
                onPressed: apply,
                child: Text(l.applyThemeColor),
              ),
              TextButton(
                onPressed: () => choose(defaultThemeColor),
                child: Text(l.resetThemeColor),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void apply() {
    final value = hex.text.trim().replaceFirst(RegExp(r'^#'), '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) {
      setState(() => invalid = true);
      return;
    }
    choose(Color(0xFF000000 | int.parse(value, radix: 16)));
  }
}
