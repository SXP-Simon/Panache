import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/fine_edit.dart';
import 'color_picker_dialog.dart';

class FineSelectionInspector extends StatelessWidget {
  const FineSelectionInspector({
    super.key,
    required this.maxHeight,
    required this.centerSummary,
    required this.count,
    required this.glyph,
    required this.navigation,
    required this.tools,
    required this.showPerspectiveHint,
    required this.sliders,
    required this.actions,
  });

  final double maxHeight;
  final bool centerSummary;
  final int count;
  final FineGlyph? glyph;
  final Widget? navigation, tools;
  final bool showPerspectiveHint;
  final Widget sliders, actions;

  String _summary(AppLocalizations l) {
    if (count == 0) return l.fineHint;
    final group = glyph?.illustrationId;
    if (count == 1 && group != null) {
      return glyph!.id == group ? l.fineDrawingLines : l.fineDrawingDetail;
    }
    return l.fineSelected(count);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scrollActions = navigation == null || maxHeight < 160;
    final summary = Text(
      _summary(l),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: centerSummary ? TextAlign.center : TextAlign.start,
      style: Theme.of(context).textTheme.bodySmall,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (centerSummary || navigation == null) summary,
                    if (navigation != null)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (!centerSummary) Flexible(child: summary),
                          Flexible(child: navigation!),
                        ],
                      ),
                    ?tools,
                    if (showPerspectiveHint)
                      Text(l.finePerspectiveHint, textAlign: TextAlign.center),
                    Visibility(
                      visible: count != 0,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: sliders,
                    ),
                    if (scrollActions && count != 0) actions,
                  ],
                ),
              ),
            ),
            if (!scrollActions)
              Visibility(
                visible: count != 0,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: actions,
              ),
          ],
        ),
      ),
    );
  }
}

class FineSelectionActions extends StatelessWidget {
  const FineSelectionActions({
    super.key,
    required this.color,
    required this.snap,
    required this.onPickColor,
    required this.onSelectDrawing,
    required this.onSnapChanged,
    required this.onReset,
  });

  final Color color;
  final bool snap;
  final VoidCallback onPickColor, onReset;
  final VoidCallback? onSelectDrawing;
  final ValueChanged<bool> onSnapChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Wrap(
      spacing: 4,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const ValueKey('fine-color'),
          onPressed: onPickColor,
          icon: ColorSwatchIndicator(color),
          label: Text(l.fineColor),
        ),
        if (onSelectDrawing != null)
          TextButton.icon(
            key: const ValueKey('fine-select-drawing'),
            onPressed: onSelectDrawing,
            icon: const Icon(Icons.select_all),
            label: Text(l.fineSelectDrawing),
          ),
        FilterChip(
          label: Text(l.fineSnap),
          selected: snap,
          onSelected: onSnapChanged,
        ),
        TextButton.icon(
          key: const ValueKey('fine-reset'),
          label: Text(l.fineReset),
          icon: const Icon(Icons.restart_alt),
          onPressed: onReset,
        ),
      ],
    );
  }
}
