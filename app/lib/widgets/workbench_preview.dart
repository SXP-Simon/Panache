import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ink_page.dart';
import '../models/fine_edit.dart';
import '../services/image_clipboard.dart';
import 'ink_parameter_controls.dart';
import 'preview_image_actions.dart';
import 'workbench_controls.dart';
import 'preview_pager.dart';
import 'fine_preview.dart';

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
    this.onFineEdit,
    this.fineAdjustments,
    this.onFineChanged,
    this.onFineHistory,
    this.canFineUndo = false,
    this.canFineRedo = false,
    this.fineSource,
    this.onFineCanvasSelect,
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
  final Future<bool> Function()? onFineEdit;
  final Map<int, FineAdjustment> Function(FinePage)? fineAdjustments;
  final void Function(FinePage, List<FineAdjustment>)? onFineChanged;
  final ValueChanged<bool>? onFineHistory;
  final bool canFineUndo, canFineRedo;
  final ValueListenable<FineRange?>? fineSource;
  final VoidCallback? onFineCanvasSelect;

  @override
  State<WorkbenchPreview> createState() => _WorkbenchPreviewState();
}

class _WorkbenchPreviewState extends State<WorkbenchPreview> {
  final _heroOwner = Object();
  bool _inkExpanded = false;
  bool _fineEditing = false;

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
        fineEdits: _fineEdits(),
        onPageChanged: (page) {
          // A viewer of an old result must not change a newly generated result.
          if (mounted && identical(source, widget.pages)) {
            widget.onPageChanged(page);
          }
        },
      ),
    );
  }

  List<Map<int, FineAdjustment>> _fineEdits() => [
    for (final page in widget.inkPages)
      if (page?.fine case final fine?)
        widget.fineAdjustments?.call(fine) ?? const {}
      else
        const {},
  ];

  Widget _editor(InkPage page, FinePage fine) {
    Widget canvas(FineRange? source) => FinePreview(
      key: ObjectKey(fine),
      page: page,
      look: widget.inkLook,
      edits: widget.fineAdjustments?.call(fine) ?? const {},
      copyImage: widget.copyImage,
      editing: !widget.stale && !widget.locked,
      toolbar: true,
      onEdit: (values) => widget.onFineChanged?.call(fine, values),
      onHistory: widget.onFineHistory,
      canUndo: widget.canFineUndo,
      canRedo: widget.canFineRedo,
      source: source,
      onCanvasSelect: widget.onFineCanvasSelect,
    );
    final source = widget.fineSource;
    return source == null
        ? canvas(null)
        : ValueListenableBuilder(
            valueListenable: source,
            builder: (_, value, _) => canvas(value),
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
    final current = widget.inkPages.elementAtOrNull(widget.page);
    final fine = current?.fine;
    return WorkbenchPanel(
      title: l.previewTitle,
      icon: Icons.description_outlined,
      toolbar: widget.toolbar,
      child: Column(
        children: [
          if (paperActions ||
              inkActions ||
              hasPages ||
              widget.onFineEdit != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (widget.onFineEdit != null)
                      FilterChip(
                        key: const ValueKey('fine-edit-toggle'),
                        label: Text(l.fineEdit),
                        avatar: const Icon(Icons.select_all, size: 17),
                        selected: _fineEditing,
                        onSelected: widget.locked
                            ? null
                            : (selected) async {
                                if (!selected) {
                                  setState(() => _fineEditing = false);
                                  return;
                                }
                                if (await widget.onFineEdit!() && mounted) {
                                  setState(() => _fineEditing = true);
                                }
                              },
                      ),
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
                  : _fineEditing && fine != null && current != null
                  ? Column(
                      children: [
                        Expanded(child: _editor(current, fine)),
                        if (widget.pages.length > 1)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: l.previousPage,
                                onPressed: widget.page > 0
                                    ? () =>
                                          widget.onPageChanged(widget.page - 1)
                                    : null,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Text(
                                '${widget.page + 1} / ${widget.pages.length}',
                              ),
                              IconButton(
                                tooltip: l.nextPage,
                                onPressed: widget.page + 1 < widget.pages.length
                                    ? () =>
                                          widget.onPageChanged(widget.page + 1)
                                    : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                      ],
                    )
                  : PreviewPager(
                      pages: widget.pages,
                      page: widget.page,
                      heroOwner: _heroOwner,
                      onOpen: _expand,
                      copyImage: widget.copyImage,
                      inkPages: widget.inkPages,
                      inkLook: widget.inkLook,
                      fineEdits: _fineEdits(),
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
