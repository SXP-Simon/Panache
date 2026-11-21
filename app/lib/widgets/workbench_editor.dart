import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/image_data.dart';
import '../utils/image_markers.dart';
import 'workbench_controls.dart';
import 'workbench_guide.dart';

class WorkbenchEditor extends StatelessWidget {
  const WorkbenchEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.undo,
    required this.locked,
    required this.toolbar,
    required this.images,
    required this.onChanged,
    this.onEditImage,
    this.onOpenGuide,
    this.guideUnread = false,
    this.onUndo,
    this.onRedo,
    this.preparing = false,
    this.preparationStopping = false,
    this.onStopPreparation,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final UndoHistoryController undo;
  final bool locked;
  final bool preparing, preparationStopping;
  final VoidCallback? onStopPreparation;
  final Widget toolbar;
  final Map<String, String> images;
  final ValueChanged<String> onChanged;
  final ValueChanged<IllustrationMarker>? onEditImage;
  final VoidCallback? onUndo, onRedo, onOpenGuide;
  final bool guideUnread;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final markers = illustrationMarkers(controller.text);
    return WorkbenchPanel(
      title: l.editor,
      icon: Icons.edit_outlined,
      actions: [
        if (controller.text.isEmpty && onOpenGuide != null)
          Semantics(
            hint: guideUnread ? l.guideUnread : null,
            child: TextButton.icon(
              key: const ValueKey('open-beginner-guide'),
              onPressed: onOpenGuide,
              icon: GuideUnreadBadge(
                unread: guideUnread,
                child: const Icon(Icons.menu_book_outlined, size: 18),
              ),
              label: Text(l.guideBeginner),
            ),
          ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: Column(
            children: [
              if (preparing) ...[
                const LinearProgressIndicator(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        preparationStopping ? l.stoppingTask : l.preparingText,
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('stop-text-preparation'),
                      onPressed: preparationStopping ? null : onStopPreparation,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(l.stopTextPreparation),
                    ),
                  ],
                ),
              ],
              toolbar,
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: math.max(
                  152,
                  constraints.maxHeight - (markers.isEmpty ? 168 : 248),
                ),
                child: Semantics(
                  identifier: 'text-input',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: colors.tertiary.withValues(alpha: .5),
                      ),
                    ),
                    child: CustomPaint(
                      painter: controller.text.isEmpty
                          ? _ManuscriptRuling(colors.tertiary)
                          : null,
                      child: TextField(
                        key: const ValueKey('text-editor'),
                        controller: controller,
                        focusNode: focusNode,
                        undoController: undo,
                        enabled: !locked,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.75,
                        ),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 17,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide(
                              color: colors.primary,
                              width: 1.5,
                            ),
                          ),
                          hintText: l.editorHint,
                          filled: false,
                        ),
                        onChanged: onChanged,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${controller.text.runes.length} ${l.characters}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  TextButton.icon(
                    label: Text(l.undo),
                    onPressed: locked ? null : (onUndo ?? undo.undo),
                    icon: const Icon(Icons.undo),
                  ),
                  TextButton.icon(
                    label: Text(l.redo),
                    onPressed: locked ? null : (onRedo ?? undo.redo),
                    icon: const Icon(Icons.redo),
                  ),
                ],
              ),
              if (markers.isEmpty)
                Text(
                  l.editorNote,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (markers.isNotEmpty) ...[
                Text(
                  l.editIllustrationHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(
                  height: 72,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final marker in markers)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: Semantics(
                            identifier: 'illustration-${marker.start}',
                            button: true,
                            child: OutlinedButton(
                              key: ValueKey('illustration-${marker.start}'),
                              onPressed: locked || onEditImage == null
                                  ? null
                                  : () => onEditImage!(marker),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _IllustrationThumbnail(
                                    source: images[marker.id] ?? '',
                                  ),
                                  const SizedBox(width: 8),
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text('#${marker.id} · ${marker.scale}%'),
                                      const Icon(Icons.tune, size: 20),
                                    ],
                                  ),
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
          ),
        ),
      ),
    );
  }
}

/// Faint writing guides on the unused portion of the blank manuscript.
class _ManuscriptRuling extends CustomPainter {
  const _ManuscriptRuling(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 72) return;
    final pen = Paint()
      ..color = ink.withValues(alpha: .18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    for (double y = 78; y < size.height - 23; y += 32) {
      canvas.drawPath(
        Path()
          ..moveTo(23, y)
          ..cubicTo(
            size.width * .34,
            y - 1.6,
            size.width * .67,
            y + 1.6,
            size.width - 23,
            y,
          ),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_ManuscriptRuling oldDelegate) => ink != oldDelegate.ink;
}

/// Retain decoded bytes across editor rebuilds instead of decoding base64 on
/// every keystroke and missing the image cache with a new Uint8List identity.
class _IllustrationThumbnail extends StatefulWidget {
  const _IllustrationThumbnail({required this.source});
  final String source;
  @override
  State<_IllustrationThumbnail> createState() => _IllustrationThumbnailState();
}

class _IllustrationThumbnailState extends State<_IllustrationThumbnail> {
  late var bytes = decodeImageData(widget.source);
  @override
  void didUpdateWidget(_IllustrationThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      bytes = decodeImageData(widget.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: Text(
          AppLocalizations.of(context)!.imageUnavailable,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    final data = bytes;
    if (data == null) return fallback;
    return Image(
      image: ResizeImage(
        MemoryImage(data),
        width: 128,
        height: 128,
        policy: ResizeImagePolicy.fit,
      ),
      width: 48,
      height: 48,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, error, stack) => fallback,
    );
  }
}
