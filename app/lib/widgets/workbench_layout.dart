import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/handwriting_theme.dart';
import '../theme/nouveau_ornament.dart';
import 'atelier_ornament.dart';
import 'fine_preview.dart';
import 'workbench_motion.dart';
import 'workbench_navigation.dart';
import 'workbench_task_status.dart';
import 'workbench_settings.dart';

class WorkbenchLayout extends StatelessWidget {
  const WorkbenchLayout({
    super.key,
    required this.wide,
    this.fineFullscreen = false,
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
    required this.fineInspector,
    required this.onDismissError,
    required this.onTabChanged,
    required this.onPreview,
    required this.onPdf,
    required this.onZip,
    this.onCancel,
  });
  final bool wide, busy, generating, keyboardVisible, fineFullscreen;
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
  final FineInspectorSlot fineInspector;
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
    final content = Column(
      children: [
        if (!fineFullscreen)
          ...workbenchTaskStatus(
            context,
            error: error,
            queueWaitSeconds: queueWaitSeconds,
            generating: generating,
            phase: phase,
            stage: stage,
            pagesCompleted: pagesCompleted,
            onCancel: onCancel,
            onDismissError: onDismissError,
          ),
        Expanded(
          key: const ValueKey('workbench-panes'),
          child: Form(
            key: formKey,
            child: wide
                ? wideWorkspace(context)
                : Padding(
                    padding: fineFullscreen
                        ? EdgeInsets.zero
                        : const EdgeInsets.all(6),
                    child: RetainedPaneSwitcher(
                      index: mobileTab,
                      children: [editorView, settingsView, buildPreview(null)],
                    ),
                  ),
          ),
        ),
        if (!wide && !keyboardVisible && !fineFullscreen) ...[
          if (mobileTab != 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: previewActions(context, mobile: true),
            ),
          const NouveauWaveDivider(height: 6),
          mobilePaneNavigation(
            context,
            selected: mobileTab,
            onSelected: onTabChanged,
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
          physics: fineFullscreen ? const NeverScrollableScrollPhysics() : null,
          child: SizedBox(
            height: !fineFullscreen && bounds.maxHeight < 450
                ? 540
                : bounds.maxHeight,
            child: content,
          ),
        );
      },
    );
  }

  bool get _expanded => WorkbenchWidth.from(width) == WorkbenchWidth.expanded;
  double get _paneGap => _expanded ? 16 : 8;

  Widget wideWorkspace(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(_paneGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder(
            valueListenable: fineInspector,
            builder: (context, inspector, _) => _wideTools(
              context,
              inspector?.hasSelection == true ? inspector : null,
            ),
          ),
          SizedBox(width: _paneGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: buildPreview(previewActions(context, mobile: false)),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
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
      ),
    );
  }

  Widget _wideTools(BuildContext context, FineInspector? inspector) {
    final l = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final editing = mobileTab != 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _expanded ? 134 : 108,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.brightness == Brightness.dark
                  ? NightSurfaces.navigation
                  : colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, bounds) => Stack(
                children: [
                  if (bounds.maxHeight > 570 &&
                      _expanded &&
                      MediaQuery.textScalerOf(context).scale(16) < 24)
                    Positioned(
                      bottom: 16,
                      left: 12,
                      right: 12,
                      child: ExcludeSemantics(
                        child: Center(
                          child: CustomPaint(
                            size: const Size(94, 157),
                            painter: AtelierBud(
                              Theme.of(context).colorScheme.onSurfaceVariant
                                  .withValues(alpha: .7),
                              Theme.of(context).colorScheme.secondary
                                  .withValues(alpha: .14),
                              Theme.of(context).colorScheme.primary
                                  .withValues(alpha: .34),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                    children: [
                      tool(
                        context,
                        l.mobileEditor,
                        Icons.edit_outlined,
                        'edit',
                        editing && inspector == null,
                        () {
                          inspector?.close();
                          onTabChanged(0);
                        },
                      ),
                      for (final section in SettingsSection.values)
                        tool(
                          context,
                          section.label(l),
                          section.icon,
                          section.name,
                          !editing &&
                              inspector == null &&
                              section == settingsSection,
                          () {
                            inspector?.close();
                            onSectionSelected(section);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(width: _paneGap),
        SizedBox(
          width: (width * .29).clamp(260.0, 430.0),
          child: RetainedPaneSwitcher(
            index: inspector != null
                ? 2
                : editing
                ? 0
                : 1,
            children: [
              editorView,
              settingsView,
              if (inspector == null)
                const SizedBox.shrink()
              else
                Builder(
                  key: const ValueKey('fine-inspector-sidebar'),
                  builder: inspector.build,
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
      style:
          (selected
                  ? selectedWorkbenchToolStyle(context)
                  : TextButton.styleFrom())
              .copyWith(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                ),
              ),
      onPressed: select,
      child: Row(
        children: [
          AnimatedSlide(
            offset: selected ? const Offset(.15, 0) : Offset.zero,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : WorkbenchMotion.selection,
            curve: WorkbenchMotion.enter,
            child: Icon(icon, size: 18),
          ),
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
