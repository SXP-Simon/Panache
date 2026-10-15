import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

Future<String?> showConnectionDialog(
  BuildContext context, {
  required String initialBase,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ConnectionDialog(initialBase),
);

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog(this.initialBase);
  final String initialBase;
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final controller = TextEditingController(text: widget.initialBase);
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.connection),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.sameOrigin),
              const SizedBox(height: 20),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: l.server,
                  errorText: error,
                ),
                keyboardType: TextInputType.url,
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
          onPressed: () {
            final value = controller.text.trim();
            final uri = Uri.tryParse(value);
            if (uri == null ||
                !['http', 'https'].contains(uri.scheme) ||
                uri.host.isEmpty ||
                uri.hasQuery ||
                uri.hasFragment ||
                uri.path.replaceAll('/', '').isNotEmpty) {
              setState(() => error = l.invalidServer);
              return;
            }
            Navigator.pop(context, value);
          },
          child: Text(l.connect),
        ),
      ],
    );
  }
}
