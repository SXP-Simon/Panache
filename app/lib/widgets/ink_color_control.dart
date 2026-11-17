import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'color_picker_dialog.dart';

class InkColorControl extends StatelessWidget {
  const InkColorControl({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<Color>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final change = onChanged;
    return OutlinedButton(
      onPressed: change == null
          ? null
          : () async {
              var previewChanged = false;
              final applied = await showDialog<Color>(
                context: context,
                builder: (_) => ColorPickerDialog(
                  id: 'ink-color',
                  title: l.inkPickColor,
                  color: color,
                  presets: [
                    (l.black, const Color(0xff000000)),
                    (l.blue, const Color(0xff003399)),
                    (l.red, const Color(0xffb40000)),
                  ],
                  onPreview: (value) {
                    previewChanged = true;
                    change(value);
                  },
                ),
              );
              if (applied == null && previewChanged && context.mounted) {
                change(color);
              }
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(l.ink)),
          const SizedBox(width: 12),
          ColorSwatchIndicator(color),
        ],
      ),
    );
  }
}
