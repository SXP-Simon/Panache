import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ink_page.dart';
import '../services/image_clipboard.dart';
import 'ink_parameter_controls.dart';
import 'preview_image_actions.dart';
import 'workbench_controls.dart';
import 'preview_pager.dart';

class WorkbenchPreview extends StatefulWidget {
  const WorkbenchPreview({
    super.key,
    required this.pages,
    this.stale = false,
    required this.page,
    required this.version,
    required this.locked,
    required this.onPageChanged,
    required this.onSaveImage,
    this.onSaveExport,
    this.onCancel,
    this.copyImage = copyPreviewImage,
    this.inkPages = const [],
    this.inkLook = defaultInkLook,
    this.onInkChanged,
    this.backgroundBytes,
    this.onAdjustBackground,
    this.toolbar,
  });
  final List<Uint8List> pages;
  final int page;
  final String version;
  final bool locked, stale;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onSaveImage;
  final VoidCallback? onSaveExport, onCancel;
  final ImageClipboardWriter copyImage;
  final List<InkPage?> inkPages;
  final InkLook inkLook;
  final ValueChanged<InkLook>? onInkChanged;
  final Uint8List? backgroundBytes;
  final VoidCallback? onAdjustBackground;
  final Widget? toolbar;

  @override
  State<WorkbenchPreview> createState() => _WorkbenchPreviewState();
}

class _WorkbenchPreviewState extends State<WorkbenchPreview> {
  final _heroOwner = Object();
  bool _inkExpanded = false;

  void _expand() {
    final source = widget.pages;
    unawaited(
      showFullscreenPreview(
        context,
        pages: List<Uint8List>.unmodifiable(source),
        page: widget.page.clamp(0, source.length - 1),
        heroOwner: _heroOwner,
        copyImage: widget.copyImage,
        inkPages: widget.inkPages,
        inkLook: widget.inkLook,
        onPageChanged: (page) {
          // A viewer of an old result must not change a newly generated result.
          if (mounted && identical(source, widget.pages)) {
            widget.onPageChanged(page);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasPages = widget.pages.isNotEmpty;
    final paperActions = widget.onAdjustBackground != null;
    final inkActions = widget.onInkChanged != null;
    return WorkbenchPanel(
      title: l.previewTitle,
      icon: Icons.description_outlined,
      toolbar: widget.toolbar,
      child: Column(
        children: [
          if (paperActions || inkActions || hasPages)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (paperActions)
                      FilledButton.tonalIcon(
                        key: const ValueKey('preview-adjust-paper-area'),
                        onPressed: widget.locked
                            ? null
                            : widget.onAdjustBackground,
                        icon: const Icon(Icons.crop_free),
                        label: Text(l.paperAreaAction),
                      ),
                    if (inkActions)
                      Semantics(
                        expanded: _inkExpanded,
                        child: FilledButton.tonalIcon(
                          style: _inkExpanded
                              ? FilledButton.styleFrom(
                                  backgroundColor: colors.primaryContainer,
                                  foregroundColor: colors.onPrimaryContainer,
                                )
                              : null,
                          key: const ValueKey('preview-ink-effects'),
                          onPressed: () =>
                              setState(() => _inkExpanded = !_inkExpanded),
                          icon: Icon(
                            _inkExpanded ? Icons.expand_less : Icons.tune,
                          ),
                          label: Text(l.inkEffects),
                        ),
                      ),
                    if (hasPages)
                      OutlinedButton.icon(
                        key: const ValueKey('expand-preview'),
                        onPressed: _expand,
                        icon: const Icon(Icons.open_in_full),
                        label: Text(l.expandPreview),
                      ),
                  ],
                ),
              ),
            ),
          if (_inkExpanded && inkActions)
            InkParameterControls(
              look: widget.inkLook,
              onChanged: widget.locked ? null : widget.onInkChanged,
              colorKey: const ValueKey('preview-ink-color'),
            ),
          if (widget.stale)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l.previewOutdated,
                key: const ValueKey('preview-stale'),
              ),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: widget.pages.isEmpty
                  ? widget.backgroundBytes != null
                        ? Image.memory(
                            widget.backgroundBytes!,
                            fit: BoxFit.contain,
                          )
                        : Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Icon(
                                        Icons.description_outlined,
                                        size: 24,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    l.previewHint,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                  : PreviewPager(
                      pages: widget.pages,
                      page: widget.page,
                      heroOwner: _heroOwner,
                      onOpen: _expand,
                      copyImage: widget.copyImage,
                      inkPages: widget.inkPages,
                      inkLook: widget.inkLook,
                      onPageChanged: widget.onPageChanged,
                    ),
            ),
          ),
          if (hasPages || widget.onCancel != null)
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.onCancel != null)
                  TextButton.icon(
                    onPressed: widget.onCancel,
                    icon: const Icon(Icons.cancel_outlined),
                    label: Text(l.cancel),
                  ),
                if (hasPages)
                  TextButton.icon(
                    onPressed: widget.locked ? null : widget.onSaveImage,
                    icon: const Icon(Icons.download),
                    label: Text(l.saveImage),
                  ),
                if (widget.onSaveExport != null)
                  TextButton.icon(
                    onPressed: widget.locked ? null : widget.onSaveExport,
                    icon: const Icon(Icons.save_alt),
                    label: Text(l.saveExport),
                  ),
              ],
            ),
          if (widget.version.isNotEmpty)
            Semantics(
              identifier: 'app-version',
              child: Text(
                'v${widget.version}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }
}
