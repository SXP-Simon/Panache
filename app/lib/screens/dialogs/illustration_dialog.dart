import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/image_data.dart';

/// Zero removes this occurrence; cancellation leaves the document untouched.
Future<int?> showIllustrationDialog(
  BuildContext context, {
  required String? source,
  int initialScale = 50,
  bool removable = false,
}) => showDialog<int>(
  context: context,
  builder: (context) => _IllustrationDialog(
    source: source,
    initialScale: initialScale,
    removable: removable,
  ),
);

class _IllustrationDialog extends StatefulWidget {
  const _IllustrationDialog({
    required this.source,
    required this.initialScale,
    required this.removable,
  });
  final String? source;
  final int initialScale;
  final bool removable;
  @override
  State<_IllustrationDialog> createState() => _IllustrationDialogState();
}

class _IllustrationDialogState extends State<_IllustrationDialog> {
  late int scale = widget.initialScale;
  late final _bytes = decodeImageData(widget.source ?? '');
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.insertImage),
      scrollable: true,
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_bytes != null)
              Image.memory(
                _bytes,
                height: 140,
                fit: BoxFit.contain,
                errorBuilder: (_, error, stack) => Text(l.imageUnavailable),
              )
            else
              Text(l.imageUnavailable),
            const SizedBox(height: 16),
            Text(l.imageScale),
            Text('$scale%', key: const ValueKey('illustration-scale-value')),
            Slider(
              key: const ValueKey('illustration-scale'),
              value: scale.toDouble(),
              min: 10,
              max: 700,
              divisions: 690,
              label: '$scale%',
              onChanged: (value) => setState(() => scale = value.round()),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.removable)
          TextButton.icon(
            key: const ValueKey('illustration-remove'),
            onPressed: () => Navigator.pop(context, 0),
            icon: const Icon(Icons.delete_outline),
            label: Text(l.removeIllustration),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('illustration-apply'),
          onPressed: _bytes == null
              ? null
              : () => Navigator.pop(context, scale),
          child: Text(l.apply),
        ),
      ],
    );
  }
}
