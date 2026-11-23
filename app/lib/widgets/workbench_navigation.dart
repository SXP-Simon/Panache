import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'workbench_motion.dart';

Widget mobilePaneNavigation(
  BuildContext context, {
  required int selected,
  required ValueChanged<int> onSelected,
}) {
  final l = AppLocalizations.of(context)!;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    child: Column(
      children: [
        Row(
          children: [
            for (final (i, key, icon, label) in [
              (0, 'back-to-editor', Icons.edit_outlined, l.mobileEditor),
              (1, 'open-paper', Icons.tune, l.parametersShort),
              (2, 'open-preview', Icons.visibility_outlined, l.mobilePreview),
            ])
              Expanded(
                child: Semantics(
                  selected: selected == i,
                  child: TextButton(
                    key: ValueKey(key),
                    style: selected == i
                        ? selectedWorkbenchToolStyle(context)
                        : null,
                    onPressed: () => onSelected(i),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSlide(
                          offset: selected == i
                              ? const Offset(0, -.1)
                              : Offset.zero,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : WorkbenchMotion.selection,
                          curve: WorkbenchMotion.enter,
                          child: Icon(icon, size: 20),
                        ),
                        Text(label, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        SizedBox(
          height: 4,
          width: double.infinity,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: 1 / 3,
              child: AnimatedSlide(
                offset: Offset(
                  selected.toDouble() *
                      (Directionality.of(context) == TextDirection.rtl
                          ? -1
                          : 1),
                  0,
                ),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : WorkbenchMotion.selection,
                curve: WorkbenchMotion.enter,
                child: Center(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: const StadiumBorder(),
                    ),
                    child: const SizedBox(width: 22, height: 3),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

ButtonStyle selectedWorkbenchToolStyle(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return TextButton.styleFrom(
    backgroundColor: colors.brightness == Brightness.dark
        ? colors.primary.withValues(alpha: .12)
        : colors.primary,
    foregroundColor: colors.brightness == Brightness.dark
        ? colors.primary
        : colors.onPrimary,
  );
}
