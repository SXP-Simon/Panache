import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'workbench_guide.dart';
import 'workbench_motion.dart';

/// Classify the window for its toolbar and the available body for its panes.
enum WorkbenchWidth {
  compact,
  medium,
  expanded;

  static WorkbenchWidth from(double width) {
    if (width < 900) return compact;
    if (width < 1100) return medium;
    return expanded;
  }
}

List<Widget> workbenchAppActions(
  AppLocalizations l, {
  required WorkbenchWidth size,
  required bool guideUnread,
  required bool updateAvailable,
  required Color foreground,
  required Color unreadColor,
  required ValueChanged<int> onDestinationSelected,
  required VoidCallback onPreferences,
  required VoidCallback onToggleLocale,
  required VoidCallback onToggleTheme,
}) {
  final compact = size == WorkbenchWidth.compact;
  return [
    if (!compact) ...[
      IconButton(
        key: const ValueKey('open-guide'),
        tooltip: guideUnread ? '${l.guide} · ${l.guideUnread}' : l.guide,
        onPressed: () => onDestinationSelected(1),
        icon: GuideUnreadBadge(
          unread: guideUnread,
          child: const Icon(Icons.menu_book_outlined),
        ),
      ),
      IconButton(
        tooltip: l.about,
        onPressed: () => onDestinationSelected(2),
        icon: Badge(
          isLabelVisible: updateAvailable,
          child: const Icon(Icons.info_outline),
        ),
      ),
    ],
    Semantics(
      hint: guideUnread && compact ? l.guideUnread : null,
      child: TextButton.icon(
        key: const ValueKey('app-preferences'),
        style: TextButton.styleFrom(foregroundColor: foreground),
        onPressed: onPreferences,
        icon: Badge(
          isLabelVisible: compact && (updateAvailable || guideUnread),
          backgroundColor: updateAvailable ? null : unreadColor,
          child: const Icon(Icons.tune),
        ),
        label: Text(l.appPreferences),
      ),
    ),
    if (size == WorkbenchWidth.expanded) ...[
      IconButton(
        tooltip: l.language,
        onPressed: onToggleLocale,
        icon: const Icon(Icons.translate),
      ),
      IconButton(
        tooltip: l.theme,
        onPressed: onToggleTheme,
        icon: const Icon(Icons.contrast),
      ),
    ],
  ];
}

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
