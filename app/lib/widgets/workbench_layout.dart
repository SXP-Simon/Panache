import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'workbench_motion.dart';
import 'workbench_settings.dart';

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
    required this.settingsSection,
    required this.onSectionSelected,
    required this.livePreview,
    required this.onLivePreview,
    required this.fullPreview,
    required this.onFullPreview,
    required this.pageCount,
    required this.formKey,
    required this.editorView,
    required this.settingsView,
    required this.buildPreview,
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
  final SettingsSection settingsSection;
  final ValueChanged<SettingsSection> onSectionSelected;
  final bool livePreview, fullPreview;
  final int pageCount;
  final ValueChanged<bool> onLivePreview, onFullPreview;
  final GlobalKey<FormState> formKey;
  final Widget editorView, settingsView;
  final Widget Function(Widget? toolbar) buildPreview;
  final VoidCallback onDismissError, onPreview, onPdf, onZip;
  final VoidCallback? onCancel;
  final ValueChanged<int> onTabChanged;
  Widget generateButton(BuildContext context) => Semantics(
    identifier: 'preview-btn',
    child: FilledButton.icon(
      key: const ValueKey('generate-preview'),
      onPressed: busy ? null : onPreview,
      icon: const Icon(Icons.visibility_outlined),
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
        Expanded(
          child: Form(
            key: formKey,
            child: wide
                ? wideWorkspace(context)
                : Padding(
                    padding: const EdgeInsets.all(6),
                    child: RetainedPaneSwitcher(
                      index: mobileTab,
                      children: [editorView, settingsView, buildPreview(null)],
                    ),
                  ),
          ),
        ),
        if (!wide && !keyboardVisible) ...[
          if (mobileTab != 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: previewActions(context, mobile: true),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                for (final (i, key, icon, label) in [
                  (0, 'back-to-editor', Icons.edit_outlined, l.mobileEditor),
                  (1, 'open-paper', Icons.tune, l.parametersShort),
                  (
                    2,
                    'open-preview',
                    Icons.visibility_outlined,
                    l.mobilePreview,
                  ),
                ])
                  Expanded(
                    child: Semantics(
                      selected: mobileTab == i,
                      child: TextButton(
                        key: ValueKey(key),
                        style: mobileTab == i
                            ? selectedToolStyle(context)
                            : null,
                        onPressed: () => onTabChanged(i),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 20),
                            Text(label, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
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

  ButtonStyle selectedToolStyle(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton.styleFrom(
      backgroundColor: colors.primaryContainer,
      foregroundColor: colors.onPrimaryContainer,
    );
  }

  Widget wideWorkspace(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final editing = mobileTab != 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 105,
          child: ListView(
            padding: const EdgeInsets.all(6),
            children: [
              tool(
                context,
                l.mobileEditor,
                Icons.edit_outlined,
                'edit',
                editing,
                () => onTabChanged(0),
              ),
              for (final section in SettingsSection.values)
                tool(
                  context,
                  section.label(l),
                  section.icon,
                  section.name,
                  !editing && section == settingsSection,
                  () => onSectionSelected(section),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: (width * .29).clamp(260.0, 430.0),
          child: RetainedPaneSwitcher(
            index: editing ? 0 : 1,
            children: [editorView, settingsView],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: buildPreview(previewActions(context, mobile: false)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 4,
                  children: exportButtons(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget tool(
    BuildContext context,
    String title,
    IconData icon,
    String id,
    bool selected,
    VoidCallback select,
  ) => Semantics(
    selected: selected,
    child: TextButton(
      key: ValueKey('workspace-tool-$id'),
      style: (selected ? selectedToolStyle(context) : TextButton.styleFrom())
          .copyWith(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 5, vertical: 8),
            ),
          ),
      onPressed: select,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Flexible(child: Text(title)),
        ],
      ),
    ),
  );

  Widget previewActions(BuildContext context, {required bool mobile}) {
    final l = AppLocalizations.of(context)!;
    final viewing = !mobile || mobileTab == 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: mobile ? WrapAlignment.center : WrapAlignment.end,
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (viewing) ...[
              FilterChip(
                key: const ValueKey('live-preview'),
                label: Text(l.livePreview),
                selected: livePreview,
                onSelected: onLivePreview,
              ),
              FilterChip(
                key: const ValueKey('full-preview'),
                label: Text(l.fullPreview),
                selected: fullPreview,
                onSelected: onFullPreview,
              ),
            ],
            generateButton(context),
            if (mobile && viewing)
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
                        builder: (sheet) => SafeArea(
                          top: false,
                          child: Padding(
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
                      ),
                icon: const Icon(Icons.ios_share),
                label: Text(l.exportOptions),
              ),
          ],
        ),
        if (viewing && livePreview && fullPreview && pageCount > 3)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              l.longLivePreview,
              key: const ValueKey('long-live-preview'),
            ),
          ),
      ],
    );
  }
}
