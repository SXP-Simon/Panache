import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'workbench_motion.dart';

class WorkbenchLayout extends StatelessWidget {
  const WorkbenchLayout({
    super.key,
    required this.wide,
    required this.keyboardVisible,
    required this.width,
    required this.error,
    this.queueWaitSeconds,
    required this.busy,
    required this.generating,
    required this.progress,
    required this.phase,
    this.stage = '',
    this.pagesCompleted = 0,
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
  final bool wide, busy, generating, keyboardVisible;
  final double width;
  final String error, phase, stage;
  final int? queueWaitSeconds;
  final int pagesCompleted;
  final int progress, mobileTab;
  final GlobalKey<FormState> formKey;
  final Widget editorView, settingsView, previewView;
  final VoidCallback onDismissError, onPreview, onPdf, onZip;
  final VoidCallback? onCancel;
  final ValueChanged<int> onTabChanged;
  Widget generateButton(BuildContext context) => Semantics(
    identifier: 'preview-btn',
    child: FilledButton.icon(
      key: const ValueKey('generate-preview'),
      onPressed: busy ? null : onPreview,
      icon: const Icon(Icons.auto_awesome_outlined),
      label: Text(AppLocalizations.of(context)!.generatePreview),
    ),
  );

  List<Widget> exportButtons(BuildContext context, {VoidCallback? close}) {
    final l = AppLocalizations.of(context)!;
    return [
      for (final action in [
        (
          'export-pdf',
          'generate-pdf-btn',
          l.exportPdf,
          Icons.picture_as_pdf_outlined,
          onPdf,
        ),
        (
          'export-zip',
          'generate-image-btn',
          l.exportZip,
          Icons.folder_zip_outlined,
          onZip,
        ),
      ])
        Semantics(
          identifier: action.$2,
          child: OutlinedButton.icon(
            key: ValueKey(action.$1),
            onPressed: busy
                ? null
                : () {
                    close?.call();
                    action.$5();
                  },
            icon: Icon(action.$4),
            label: Text(action.$3),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final taskStatus = generating
        ? Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                if (onCancel != null)
                  TextButton.icon(
                    key: const ValueKey('cancel-generation'),
                    onPressed: onCancel,
                    icon: const Icon(Icons.cancel_outlined),
                    label: Text(l.stopGeneration),
                  ),
                Text(
                  generating
                      ? switch (phase) {
                          'pending' => l.pending,
                          'completed' => l.completed,
                          'cancelling' => l.stoppingTask,
                          _ =>
                            stage == 'exporting'
                                ? l.exportingTask
                                : l.processing,
                        }
                      : l.processing,
                ),
                if (pagesCompleted > 0) Text(l.generatedPages(pagesCompleted)),
              ],
            ),
          )
        : const SizedBox(width: double.infinity);
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
                      : queueWaitSeconds != null
                      ? '${l.queueFull} ${queueWaitSeconds}s'
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
        if (MediaQuery.disableAnimationsOf(context))
          taskStatus
        else
          AnimatedSize(
            duration: WorkbenchMotion.pane,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: taskStatus,
          ),
        if (!wide && mobileTab != 0)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('back-to-editor'),
              onPressed: () => onTabChanged(0),
              icon: const Icon(Icons.arrow_back),
              label: Text(l.backToEditor),
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
                          child: RetainedPaneSwitcher(
                            index: mobileTab,
                            children: [editorView, settingsView, previewView],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        if (!keyboardVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: wide
                ? Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      generateButton(context),
                      ...exportButtons(context),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (mobileTab == 0)
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            TextButton.icon(
                              key: const ValueKey('open-paper'),
                              onPressed: () => onTabChanged(1),
                              icon: const Icon(Icons.tune),
                              label: Text(l.paperSettings),
                            ),
                            TextButton.icon(
                              key: const ValueKey('open-preview'),
                              onPressed: () => onTabChanged(2),
                              icon: const Icon(Icons.visibility_outlined),
                              label: Text(l.viewPreview),
                            ),
                          ],
                        ),
                      generateButton(context),
                      if (mobileTab == 2)
                        TextButton.icon(
                          key: const ValueKey('open-export'),
                          onPressed: busy
                              ? null
                              : () => showModalBottomSheet<void>(
                                  sheetAnimationStyle:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? AnimationStyle.noAnimation
                                      : null,
                                  context: context,
                                  showDragHandle: true,
                                  useSafeArea: true,
                                  builder: (sheet) => Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: exportButtons(
                                        context,
                                        close: () => Navigator.pop(sheet),
                                      ),
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.ios_share),
                          label: Text(l.exportOptions),
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
