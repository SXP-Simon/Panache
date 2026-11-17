import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ink_page.dart';
import '../services/image_clipboard.dart';
import 'ink_color_control.dart';
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
    return WorkbenchPanel(
      title: l.previewTitle,
      icon: Icons.description_outlined,
      child: Column(
        children: [
          if (widget.onInkChanged != null || widget.onAdjustBackground != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                alignment: WrapAlignment.end,
                children: [
                  if (widget.onAdjustBackground != null)
                    TextButton.icon(
                      key: const ValueKey('preview-adjust-paper-area'),
                      onPressed: widget.locked
                          ? null
                          : widget.onAdjustBackground,
                      icon: const Icon(Icons.crop_free),
                      label: Text(l.paperAreaAction),
                    ),
                  if (widget.onInkChanged != null)
                    TextButton.icon(
                      key: const ValueKey('preview-ink-effects'),
                      onPressed: () =>
                          setState(() => _inkExpanded = !_inkExpanded),
                      icon: const Icon(Icons.tune),
                      label: Text(l.inkEffects),
                    ),
                ],
              ),
            ),
          if (_inkExpanded && widget.onInkChanged != null) _inkControls(l),
          if (widget.stale)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l.previewOutdated,
                key: const ValueKey('preview-stale'),
              ),
            ),
          if (widget.pages.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('expand-preview'),
                onPressed: _expand,
                icon: const Icon(Icons.open_in_full),
                label: Text(l.expandPreview),
              ),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: widget.pages.isEmpty
                  ? widget.backgroundBytes != null
                        ? Image.memory(
                            widget.backgroundBytes!,
                            fit: BoxFit.contain,
                          )
                        : Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.draw_outlined,
                                    size: 56,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                    l.previewHint,
                                    textAlign: TextAlign.center,
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
          if (widget.pages.isNotEmpty || widget.onCancel != null)
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
                if (widget.pages.isNotEmpty)
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

  Widget _inkControls(AppLocalizations l) {
    final look = widget.inkLook;
    final change = widget.onInkChanged!;
    Widget slider(
      String name,
      String key,
      num value,
      int min,
      int max,
      ValueChanged<double> set, {
      bool fractional = false,
    }) => Row(
      children: [
        Expanded(
          child: Text(
            fractional
                ? '$name ${value.toStringAsFixed(1)} px'
                : '$name $value%',
          ),
        ),
        Expanded(
          child: Slider(
            key: ValueKey(key),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: (max - min) * (fractional ? 10 : 1),
            value: value.toDouble(),
            label: value.toStringAsFixed(fractional ? 1 : 0),
            onChanged: (value) =>
                set(fractional ? (value * 10).round() / 10 : value),
          ),
        ),
      ],
    );
    return Column(
      children: [
        slider(
          l.inkOpacity,
          'ink-opacity',
          look.opacity,
          0,
          100,
          (v) => change((
            opacity: v.round(),
            thickness: look.thickness,
            softness: look.softness,
            color: look.color,
          )),
        ),
        slider(
          l.inkThickness,
          'ink-thickness',
          look.thickness,
          -2,
          2,
          (v) => change((
            opacity: look.opacity,
            thickness: v,
            softness: look.softness,
            color: look.color,
          )),
          fractional: true,
        ),
        slider(
          l.inkSoftness,
          'ink-softness',
          look.softness,
          0,
          2,
          (v) => change((
            opacity: look.opacity,
            thickness: look.thickness,
            softness: v,
            color: look.color,
          )),
          fractional: true,
        ),
        InkColorControl(
          key: const ValueKey('preview-ink-color'),
          color: Color(look.color),
          onChanged: widget.locked
              ? null
              : (color) {
                  final current = widget.inkLook;
                  widget.onInkChanged?.call((
                    opacity: current.opacity,
                    thickness: current.thickness,
                    softness: current.softness,
                    color: color.toARGB32(),
                  ));
                },
        ),
      ],
    );
  }
}
