import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

enum GuideTarget { editor, layout, preview }

class GuideUnreadBadge extends StatelessWidget {
  const GuideUnreadBadge({
    super.key,
    required this.unread,
    required this.child,
  });

  final bool unread;
  final Widget child;

  @override
  Widget build(BuildContext context) => Badge(
    smallSize: 8,
    backgroundColor: Theme.of(context).colorScheme.primary,
    isLabelVisible: unread,
    child: child,
  );
}

class WorkbenchGuide extends StatelessWidget {
  const WorkbenchGuide({super.key, required this.onOpen});

  final ValueChanged<GuideTarget> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final steps = [
      (l.guideWriteTitle, l.guideWriteHint, GuideTarget.editor),
      (l.guideFontTitle, l.guideFontHint, GuideTarget.layout),
      (l.guidePreviewTitle, l.guidePreviewHint, GuideTarget.preview),
      (l.guideExportTitle, l.guideExportHint, GuideTarget.preview),
    ];
    final topics = [
      (
        'preview',
        Icons.visibility_outlined,
        l.guidePreviewOptionsTitle,
        l.guidePreviewOptionsHint,
      ),
      ('math', Icons.functions, l.guideMathTitle, l.guideMathHint),
      (
        'table',
        Icons.table_chart_outlined,
        l.guideTableTitle,
        l.guideTableHint,
      ),
      ('image', Icons.image_outlined, l.guideImageTitle, l.guideImageHint),
      (
        'paper',
        Icons.description_outlined,
        l.guidePaperTitle,
        l.guidePaperHint,
      ),
      ('fine', Icons.select_all, l.guideFineTitle, l.guideFineHint),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          key: const ValueKey('beginner-guide'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Semantics(
              header: true,
              child: Text(
                l.guideBeginner,
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 4),
            Text(l.guideIntro, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Card.outlined(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (index, (title, hint, target))
                      in steps.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    ListTile(
                      key: ValueKey('guide-step-${index + 1}'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        foregroundColor: theme.colorScheme.onPrimaryContainer,
                        child: Text('${index + 1}'),
                      ),
                      title: Text(title),
                      subtitle: Text(hint),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => onOpen(target),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(l.guidePractice, style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 4),
            for (final (id, icon, title, hint) in topics)
              ExpansionTile(
                key: PageStorageKey('guide-topic-$id'),
                tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                leading: Icon(icon, size: 20),
                title: Text(title),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Text(hint, style: theme.textTheme.bodyMedium)],
              ),
          ],
        ),
      ),
    );
  }
}
