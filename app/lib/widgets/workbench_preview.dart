import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ink_page.dart';
import '../services/image_clipboard.dart';
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

  @override
  State<WorkbenchPreview> createState() => _WorkbenchPreviewState();
}

class _WorkbenchPreviewState extends State<WorkbenchPreview> {
  final _heroOwner = Object();
  late final _inkColor = TextEditingController(text: _colorHex(widget.inkLook));
  bool _inkExpanded = false;

  static String _colorHex(InkLook look) =>
      '#${(look.color & 0xffffff).toRadixString(16).padLeft(6, '0')}';

  static int? _parseHex(String input) {
    final hex = input.trim().replaceFirst(RegExp(r'^#'), '');
    return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)
        ? int.parse(hex, radix: 16)
        : null;
  }

  @override
  void didUpdateWidget(WorkbenchPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final color = widget.inkLook.color;
    if (oldWidget.inkLook.color != color &&
        _parseHex(_inkColor.text) != (color & 0xffffff)) {
      _inkColor.text = _colorHex(widget.inkLook);
    }
  }

  @override
  void dispose() {
    _inkColor.dispose();
    super.dispose();
  }

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
          if (widget.onInkChanged != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('preview-ink-effects'),
                onPressed: () => setState(() => _inkExpanded = !_inkExpanded),
                icon: const Icon(Icons.tune),
                label: Text(l.inkEffects),
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
    void selectColor(int color) => change((
      opacity: look.opacity,
      thickness: look.thickness,
      softness: look.softness,
      color: color,
    ));
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
        Wrap(
          spacing: 6,
          children: [
            for (final (label, color) in [
              (l.black, 0xff000000),
              (l.blue, 0xff003399),
              (l.red, 0xffb40000),
            ])
              ChoiceChip(
                label: Text(label),
                selected: look.color == color,
                onSelected: (_) => selectColor(color),
              ),
            SizedBox(
              width: 116,
              child: TextField(
                key: const ValueKey('preview-ink-color'),
                controller: _inkColor,
                decoration: InputDecoration(
                  labelText: l.ink,
                  hintText: '#000000',
                  isDense: true,
                ),
                onChanged: (input) {
                  if (_parseHex(input) case final rgb?) {
                    selectColor(0xff000000 | rgb);
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
