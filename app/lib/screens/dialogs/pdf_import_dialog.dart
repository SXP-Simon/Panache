import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pdf_pages.dart';

Future<PdfImportMode?> choosePdfImport(BuildContext context, String engine) {
  final l = AppLocalizations.of(context)!;
  final host = Uri.tryParse(engine)?.host ?? '';
  final local =
      engine.startsWith('local://') ||
      ['localhost', '127.0.0.1', '::1'].contains(host);
  return showDialog<PdfImportMode>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.pdfImport),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final choice in [
                (PdfImportMode.text, Icons.subject, l.pdfText, l.pdfTextHint),
                (
                  PdfImportMode.layout,
                  Icons.space_dashboard_outlined,
                  l.pdfLayout,
                  l.pdfLayoutHint,
                ),
                (PdfImportMode.fill, Icons.edit_note, l.pdfFill, l.pdfFillHint),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(choice.$2),
                  title: Text(choice.$3),
                  subtitle: Text(choice.$4),
                  onTap: () => Navigator.pop(context, choice.$1),
                ),
              const Divider(),
              Text(
                local ? l.pdfLocal : l.pdfRemote(engine),
                style: Theme.of(context).textTheme.bodySmall,
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
      ],
    ),
  );
}
