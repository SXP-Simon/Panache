import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/image_data.dart';
import 'workbench_controls.dart';

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
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final UndoHistoryController undo;
  final bool locked;
  final Widget toolbar;
  final Map<String, String> images;
  final ValueChanged<String> onChanged;
  Widget thumbnail(AppLocalizations l, String source) {
    final bytes = decodeImageData(source);
    final fallback = SizedBox(
      width: 64,
      height: 64,
      child: Center(
        child: Text(l.imageUnavailable, textAlign: TextAlign.center),
      ),
    );
    if (bytes == null) return fallback;
    return Image.memory(
      bytes,
      width: 64,
      height: 64,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return WorkbenchPanel(
      title: l.editor,
      icon: Icons.edit_outlined,
      child: Column(
        children: [
          toolbar,
          const SizedBox(height: 12),
          Expanded(
            child: Semantics(
              identifier: 'text-input',
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
                decoration: InputDecoration(
                  hintText: l.editorHint,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                ),
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${controller.text.runes.length} ${l.characters}'),
              TextButton.icon(
                label: Text(l.undo),
                onPressed: locked ? null : undo.undo,
                icon: const Icon(Icons.undo),
              ),
              TextButton.icon(
                label: Text(l.redo),
                onPressed: locked ? null : undo.redo,
                icon: const Icon(Icons.redo),
              ),
            ],
          ),
          Text(l.editorNote, style: Theme.of(context).textTheme.bodySmall),
          if (images.isNotEmpty)
            SizedBox(
              height: 72,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final image in images.entries)
                    if (controller.text.contains('插图 ${image.key}'))
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: Tooltip(
                          message: '![插图 ${image.key}]',
                          child: thumbnail(l, image.value),
                        ),
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
