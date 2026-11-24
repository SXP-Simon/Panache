import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

class PdfWorkbenchLayout extends StatelessWidget {
  const PdfWorkbenchLayout({
    super.key,
    required this.fileName,
    required this.fill,
    required this.warning,
    required this.index,
    required this.count,
    required this.onClose,
    required this.onExport,
    required this.onPrevious,
    required this.onNext,
    required this.child,
  });

  final String fileName;
  final bool fill;
  final String? warning;
  final int index, count;
  final VoidCallback onClose;
  final VoidCallback? onExport, onPrevious, onNext;
  final Widget child;

  Widget _header(BuildContext context, AppLocalizations l) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.picture_as_pdf_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fileName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(fill ? l.pdfFillHelp : l.pdfLayoutHelp),
          if (warning case final message?)
            Text(message, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
    );
  }

  Widget _navigation(AppLocalizations l) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: l.previousPage,
        onPressed: onPrevious,
        icon: const Icon(Icons.chevron_left),
      ),
      Text(count == 0 ? '—' : '${index + 1} / $count'),
      IconButton(
        tooltip: l.nextPage,
        onPressed: onNext,
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l.close,
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
        title: Text(fill ? l.pdfFill : l.pdfLayout),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: onExport,
              icon: const Icon(Icons.file_download_outlined),
              label: Text(l.exportPdf),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _header(context, l),
            const Divider(height: 1),
            Expanded(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(child: child),
                ),
              ),
            ),
            _navigation(l),
          ],
        ),
      ),
    );
  }
}
