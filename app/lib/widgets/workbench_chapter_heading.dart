import 'package:flutter/material.dart';

import '../theme/nouveau_ornament.dart';

/// Chapter opening shared by the guide and the application colophon.
class WorkbenchChapterHeading extends StatelessWidget {
  const WorkbenchChapterHeading({
    super.key,
    required this.title,
    required this.introduction,
    required this.emblem,
  });

  final String title, introduction;
  final Widget emblem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(title, style: theme.textTheme.headlineMedium),
                  ),
                ),
                const SizedBox(width: 12),
                emblem,
              ],
            ),
            const NouveauWaveDivider(height: 24),
            Text(
              introduction,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.65),
            ),
          ],
        ),
      ),
    );
  }
}
