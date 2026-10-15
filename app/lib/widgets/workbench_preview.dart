import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'workbench_controls.dart';

class WorkbenchPreview extends StatelessWidget {
  const WorkbenchPreview({
    super.key,
    required this.pages,
    required this.page,
    required this.version,
    required this.locked,
    required this.onPageChanged,
    required this.onSaveImage,
    this.onSaveExport,
    this.onCancel,
  });
  final List<Uint8List> pages;
  final int page;
  final String version;
  final bool locked;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onSaveImage;
  final VoidCallback? onSaveExport, onCancel;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return WorkbenchPanel(
      title: l.previewTitle,
      icon: Icons.description_outlined,
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: pages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.draw_outlined,
                              size: 56,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 24),
                            Text(l.previewHint, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    )
                  : InteractiveViewer(
                      minScale: .25,
                      maxScale: 5,
                      child: Center(
                        child: Semantics(
                          identifier: 'preview-image',
                          child: Image.memory(
                            pages[page],
                            key: ValueKey('page-$page-${pages[page].hashCode}'),
                            fit: BoxFit.contain,
                            semanticLabel: l.preview,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          if (pages.isNotEmpty)
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  label: Text(l.previousPage),
                  onPressed: page > 0 ? () => onPageChanged(page - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('${page + 1} / ${pages.length}'),
                TextButton.icon(
                  label: Text(l.nextPage),
                  onPressed: page < pages.length - 1
                      ? () => onPageChanged(page + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          if (onCancel != null)
            TextButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.cancel_outlined),
              label: Text(l.cancel),
            ),
          if (pages.isNotEmpty)
            TextButton.icon(
              onPressed: locked ? null : onSaveImage,
              icon: const Icon(Icons.download),
              label: Text(l.saveImage),
            ),
          if (onSaveExport != null)
            TextButton.icon(
              onPressed: locked ? null : onSaveExport,
              icon: const Icon(Icons.save_alt),
              label: Text(l.saveExport),
            ),
          if (version.isNotEmpty)
            Semantics(
              identifier: 'app-version',
              child: Text(
                'v$version',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }
}
