import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

class WorkbenchLayout extends StatelessWidget {
  const WorkbenchLayout({
    super.key,
    required this.wide,
    required this.width,
    required this.error,
    required this.busy,
    required this.generating,
    required this.progress,
    required this.phase,
    required this.mobileTab,
    required this.formKey,
    required this.editorView,
    required this.settingsView,
    required this.previewView,
    required this.onDismissError,
    required this.onTabChanged,
    required this.onPreview,
    required this.onPdf,
    required this.onZip,
    this.onCancel,
  });
  final bool wide, busy, generating;
  final double width;
  final String error, phase;
  final int progress, mobileTab;
  final GlobalKey<FormState> formKey;
  final Widget editorView, settingsView, previewView;
  final VoidCallback onDismissError, onPreview, onPdf, onZip;
  final VoidCallback? onCancel;
  final ValueChanged<int> onTabChanged;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final content = Column(
      children: [
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(16),
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(
                  error == 'validation'
                      ? l.validation
                      : error.startsWith('queue:')
                      ? '${l.queueFull} ${error.split(':').last}s'
                      : error,
                ),
                trailing: TextButton.icon(
                  label: Text(l.close),
                  onPressed: onDismissError,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ),
        if (busy)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: generating && progress > 0 ? progress / 100 : null,
                ),
                const SizedBox(height: 8),
                if (onCancel != null)
                  TextButton.icon(
                    key: const ValueKey('cancel-generation'),
                    onPressed: onCancel,
                    icon: const Icon(Icons.cancel_outlined),
                    label: Text(l.cancel),
                  ),
                Text(
                  generating
                      ? '${switch (phase) {
                          'pending' => l.pending,
                          'completed' => l.completed,
                          _ => l.processing,
                        }} · $progress%'
                      : l.processing,
                ),
              ],
            ),
          ),
        if (!wide)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                style: SegmentedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  iconSize: 18,
                  minimumSize: const Size(0, 48),
                ),
                segments: [
                  ButtonSegment(
                    value: 0,
                    label: Text(l.mobileEditor),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  ButtonSegment(
                    value: 1,
                    label: Text(l.mobilePaper),
                    icon: const Icon(Icons.tune),
                  ),
                  ButtonSegment(
                    value: 2,
                    label: Text(l.mobilePreview),
                    icon: const Icon(Icons.visibility_outlined),
                  ),
                ],
                selected: {mobileTab},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  FocusScope.of(context).unfocus();
                  onTabChanged(s.first);
                },
              ),
            ),
          ),
        Expanded(
          child: Form(
            key: formKey,
            child: Padding(
              padding: EdgeInsets.all(wide ? 20 : 8),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: width >= 1300 ? 320 : 260,
                          child: settingsView,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: editorView),
                        const SizedBox(width: 12),
                        Expanded(child: previewView),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, area) => SingleChildScrollView(
                        child: SizedBox(
                          height: area.maxHeight
                              .clamp(360.0, double.infinity)
                              .toDouble(),
                          child: IndexedStack(
                            index: mobileTab,
                            children: [editorView, settingsView, previewView],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        if (MediaQuery.viewInsetsOf(context).bottom == 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                Semantics(
                  identifier: 'preview-btn',
                  child: FilledButton.icon(
                    key: const ValueKey('generate-preview'),
                    onPressed: busy ? null : onPreview,
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(l.preview),
                  ),
                ),
                Semantics(
                  identifier: 'generate-pdf-btn',
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('export-pdf'),
                    onPressed: busy ? null : onPdf,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: Text(l.exportPdf),
                  ),
                ),
                Semantics(
                  identifier: 'generate-image-btn',
                  child: OutlinedButton.icon(
                    key: const ValueKey('export-zip'),
                    onPressed: busy ? null : onZip,
                    icon: const Icon(Icons.folder_zip_outlined),
                    label: Text(l.exportZip),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (wide) return content;
        // Keep the editor's element ancestry stable while the keyboard changes
        // available height, otherwise EditableText is disposed mid-composition.
        return SingleChildScrollView(
          child: SizedBox(
            height: bounds.maxHeight < 450 ? 540 : bounds.maxHeight,
            child: content,
          ),
        );
      },
    );
  }
}
