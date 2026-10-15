import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

typedef LetterInputs = ({String body, String signature, String date});

Future<String?> showMarkdownDialog(
  BuildContext context, {
  required String initialMode,
}) async {
  final l = AppLocalizations.of(context)!;
  var selected = initialMode;
  final accepted = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(l.markdown),
        content: DropdownButtonFormField<String>(
          initialValue: selected,
          decoration: InputDecoration(labelText: l.tableMode),
          items: [
            for (final option in [
              ('list', l.listMode),
              ('aligned', l.alignedMode),
              ('raw_pipe', l.pipeMode),
              ('clean', l.cleanMode),
            ])
              DropdownMenuItem(value: option.$1, child: Text(option.$2)),
          ],
          onChanged: (v) => update(() => selected = v!),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, selected),
            child: Text(l.apply),
          ),
        ],
      ),
    ),
  );
  return accepted;
}

Future<LetterInputs?> showLetterDialog(
  BuildContext context, {
  required LetterInputs initial,
}) => showDialog<LetterInputs>(
  context: context,
  builder: (_) => _LetterDialog(initial),
);

class _LetterDialog extends StatefulWidget {
  const _LetterDialog(this.initial);
  final LetterInputs initial;
  @override
  State<_LetterDialog> createState() => _LetterDialogState();
}

class _LetterDialogState extends State<_LetterDialog> {
  late final body = TextEditingController(text: widget.initial.body);
  late final signature = TextEditingController(text: widget.initial.signature);
  late final date = TextEditingController(text: widget.initial.date);
  @override
  void dispose() {
    body.dispose();
    signature.dispose();
    date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.letter),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: body,
                minLines: 4,
                maxLines: 8,
                decoration: InputDecoration(labelText: l.body),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: signature,
                decoration: InputDecoration(labelText: l.signature),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: date,
                decoration: InputDecoration(labelText: l.date),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            body: body.text,
            signature: signature.text,
            date: date.text,
          )),
          child: Text(l.apply),
        ),
      ],
    );
  }
}
