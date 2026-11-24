import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/image_markers.dart';
import 'editor_illustration_strip.dart';
import 'manuscript_text_field.dart';
import 'workbench_controls.dart';
import 'workbench_guide.dart';

// Inspect only the text near the caret, even for a long report.
final _ratioInput = RegExp(
  r'(?:^|[\s，。；：、（(=])([a-zA-Z0-9]+ */ *[a-zA-Z0-9]*)(?=$|[\s，。；：、）).,;!?])',
);

bool _editingRatio(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isCollapsed || !selection.isValid) return false;
  final offset = selection.extentOffset;
  final start = math.max(0, offset - 100);
  final end = math.min(value.text.length, offset + 100);
  final window = value.text.substring(start, end);
  for (final match in _ratioInput.allMatches(window)) {
    final tokenStart = match.end - match[1]!.length;
    if (offset - start > tokenStart && offset - start <= match.end) return true;
  }
  return false;
}

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

  Widget _historyControls(ThemeData theme, AppLocalizations l) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        '${controller.text.runes.length} ${l.characters}',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
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
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
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
                child: ManuscriptTextField(
                  controller: controller,
                  focusNode: focusNode,
                  undo: undo,
                  enabled: !locked,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(height: 8),
              _historyControls(theme, l),
              ListenableBuilder(
                listenable: Listenable.merge([controller, focusNode]),
                builder: (context, _) {
                  final showHint =
                      focusNode.hasFocus && _editingRatio(controller.value);
                  if (!showHint && markers.isNotEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    showHint ? l.editorSlashHint : l.editorNote,
                    style: theme.textTheme.bodySmall,
                  );
                },
              ),
              if (markers.isNotEmpty) ...[
                Text(
                  l.editIllustrationHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                EditorIllustrationStrip(
                  markers: markers,
                  images: images,
                  onEditImage: locked ? null : onEditImage,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
