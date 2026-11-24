import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/handwriting_theme.dart';

class ManuscriptTextField extends StatelessWidget {
  const ManuscriptTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.undo,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final UndoHistoryController undo;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      identifier: 'text-input',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? NightSurfaces.writing
              : colors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: theme.brightness == Brightness.dark
                ? colors.outlineVariant
                : colors.tertiary.withValues(alpha: .5),
          ),
        ),
        child: CustomPaint(
          painter: controller.text.isEmpty
              ? _ManuscriptRuling(colors.tertiary)
              : null,
          child: TextField(
            key: const ValueKey('text-editor'),
            controller: controller,
            focusNode: focusNode,
            undoController: undo,
            enabled: enabled,
            expands: true,
            maxLines: null,
            minLines: null,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.75),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 17,
              ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide(color: colors.primary, width: 1.5),
              ),
              hintText: l.editorHint,
              filled: false,
            ),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

/// Faint writing guides on the unused portion of the blank manuscript.
class _ManuscriptRuling extends CustomPainter {
  const _ManuscriptRuling(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 72) return;
    final pen = Paint()
      ..color = ink.withValues(alpha: .18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    for (double y = 78; y < size.height - 23; y += 32) {
      canvas.drawPath(
        Path()
          ..moveTo(23, y)
          ..cubicTo(
            size.width * .34,
            y - 1.6,
            size.width * .67,
            y + 1.6,
            size.width - 23,
            y,
          ),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_ManuscriptRuling oldDelegate) => ink != oldDelegate.ink;
}
