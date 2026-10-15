import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/math_segments.dart';

Future<void> showTextPreviewDialog(
  BuildContext context, {
  required String text,
  required void Function(Uri) onOpenLink,
}) {
  final l = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.textPreview),
      content: SizedBox(
        width: 640,
        height: 440,
        child: ListView(
          children: [
            MarkdownBody(
              data: text,
              selectable: true,
              onTapLink: (_, href, _) {
                if (href != null &&
                    ['http', 'https'].contains(Uri.tryParse(href)?.scheme)) {
                  onOpenLink(Uri.parse(href));
                }
              },
            ),
            const Divider(),
            for (final segment in scanMathSegments(text).where((s) => s.math))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Math.tex(
                    segment.body,
                    onErrorFallback: (_) =>
                        Text(text.substring(segment.start, segment.end)),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.close),
        ),
      ],
    ),
  );
}
