import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/engine_failure.dart';
import '../models/upload.dart';
import '../services/pdf_pages.dart';
import '../services/pdf_writing_export.dart';
import '../widgets/pdf_workbench_layout.dart';
import '../widgets/pdf_writing_surface.dart';

class PdfWorkbench extends StatefulWidget {
  const PdfWorkbench({
    super.key,
    required this.file,
    required this.mode,
    required this.fetch,
    required this.loadFont,
    required this.ink,
    required this.save,
  });
  final Upload file;
  final PdfImportMode mode;
  final Future<PdfSourcePage> Function(int index) fetch;
  final Future<String> Function() loadFont;
  final Color ink;
  final Future<void> Function(Uint8List pdf) save;

  @override
  State<PdfWorkbench> createState() => _PdfWorkbenchState();
}

class _PdfWorkbenchState extends State<PdfWorkbench> {
  final edits = <int, List<PdfWritingBox>>{};
  final recentPages = <int, PdfSourcePage>{};
  PdfSourcePage? page;
  int index = 0, count = 0;
  int? exporting;
  bool dirty = false, leaving = false;
  String? family;
  Object? failure;

  AppLocalizations get l => AppLocalizations.of(context)!;
  bool get fill => widget.mode == PdfImportMode.fill;
  Iterable<String> relevantWarnings(PdfSourcePage source) => fill
      ? source.warnings.where((w) => w == 'partial_render')
      : source.warnings;
  List<PdfWritingBox> boxesFor(PdfSourcePage source) =>
      edits[source.index] ?? (fill ? const <PdfWritingBox>[] : source.lines);

  @override
  void initState() {
    super.initState();
    load(0);
  }

  Future<PdfSourcePage> readPage(int index) async {
    final result = recentPages.remove(index) ?? await widget.fetch(index);
    recentPages[index] = result;
    while (recentPages.length > 1 &&
        (recentPages.length > 4 ||
            recentPages.values.fold<int>(
                  0,
                  (sum, page) => sum + page.paper.length,
                ) >
                8 * 1024 * 1024)) {
      recentPages.remove(recentPages.keys.first);
    }
    return result;
  }

  Future<void> load(int value) async {
    setState(() {
      index = value;
      page = null;
      failure = null;
    });
    try {
      family ??= await widget.loadFont();
      if (!mounted) return;
      final result = await readPage(value);
      if (mounted) {
        setState(() {
          page = result;
          count = result.count;
        });
      }
    } catch (e) {
      if (mounted) setState(() => failure = e);
    }
  }

  String errorText(Object e) {
    if (family == null) return l.pdfFontError;
    if (e is ApiException) {
      return switch (e.code) {
        'encrypted_pdf' => l.pdfEncrypted,
        'archive_limit' ||
        'upload_limit' ||
        'page_limit' ||
        'text_limit' ||
        'pixel_limit' ||
        'pdf_export_limit' => l.pdfLimit,
        'invalid_document' => l.pdfInvalid,
        _ =>
          e.status == 404 || e.code == 'invalid_command'
              ? l.pdfEngineOld
              : l.pdfFailed(e.toString()),
      };
    }
    return l.pdfFailed(e.toString());
  }

  Future<void> editBox(Rect rect, {int? at}) async {
    final source = page;
    if (source == null || exporting != null) return;
    final boxes = boxesFor(source);
    final previous = at == null ? null : boxes[at];
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _AnswerDialog(
        initial: previous?.text ?? '',
        existing: previous != null,
      ),
    );
    if (!mounted || result == null || result == previous?.text) return;
    final next = [...boxes];
    if (result.trim().isEmpty) {
      if (at == null) return;
      next.removeAt(at);
    } else {
      final box = PdfWritingBox(rect, result, wrap: previous?.wrap ?? true);
      if (at == null) {
        next.add(box);
      } else {
        next[at] = box;
      }
    }
    setState(() {
      edits[index] = next;
      dirty = true;
    });
  }

  Future<void> close() async {
    if (dirty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.pdfCloseTitle),
          content: Text(l.pdfCloseHint),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.close),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<bool?> _confirmExport(int issues) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.pdfReview),
      content: Text(l.pdfWarnings(issues)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l.exportPdf),
        ),
      ],
    ),
  );

  Future<void> export() async {
    final current = page;
    if (current == null || family == null || exporting != null) return;
    setState(() => exporting = 0);
    try {
      final prepared = await assembleWritingPdf(
        current: current,
        readPage: readPage,
        isActive: () => mounted && !leaving,
        onPageStarted: (number) => setState(() => exporting = number),
        writingFor: (source) => (
          needsReview:
              relevantWarnings(source).isNotEmpty ||
              (!fill && source.lines.isEmpty),
          boxes: boxesFor(source),
          font: family!,
          ink: widget.ink,
        ),
      );
      if (!mounted || leaving || prepared == null) return;
      if (prepared.reviewCount != 0) {
        final confirmed = await _confirmExport(prepared.reviewCount);
        if (!mounted || confirmed != true) return;
      }
      final bytes = await prepared.document.finish();
      if (!mounted || leaving) return;
      await widget.save(bytes);
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.errorTitle),
            content: Text(errorText(e)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l.close),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = null);
    }
  }

  String? _warningFor(PdfSourcePage? source) {
    if (source == null) return null;
    if (!fill && source.lines.isEmpty) return l.pdfNoText;
    return relevantWarnings(source).isNotEmpty ? l.pdfPartial : null;
  }

  Widget _pageContent(PdfSourcePage? source) {
    final progress = exporting;
    if (progress != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(l.pdfProgress(progress, count)),
        ],
      );
    }
    final error = failure;
    if (error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(errorText(error), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => load(index),
            icon: const Icon(Icons.refresh),
            label: Text(l.retry),
          ),
        ],
      );
    }
    if (source == null) return const CircularProgressIndicator();
    return PdfWritingSurface(
      key: ValueKey(index),
      page: source,
      boxes: boxesFor(source),
      family: family!,
      ink: widget.ink,
      fill: fill,
      onAdd: (r) => editBox(r),
      onEdit: (i) => editBox(boxesFor(source)[i].rect, at: i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = page;
    final available = exporting == null;
    final canNavigate = available && (source != null || failure != null);
    return PopScope(
      canPop: leaving || !dirty,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) close();
      },
      child: PdfWorkbenchLayout(
        fileName: widget.file.name,
        fill: fill,
        warning: _warningFor(source),
        index: index,
        count: count,
        onClose: close,
        onExport: source != null && available ? export : null,
        onPrevious: canNavigate && index > 0 ? () => load(index - 1) : null,
        onNext: canNavigate && index + 1 < count ? () => load(index + 1) : null,
        child: _pageContent(source),
      ),
    );
  }
}

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog({required this.initial, required this.existing});
  final String initial;
  final bool existing;
  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.pdfBoxText),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          maxLength: 2000,
        ),
      ),
      actions: [
        if (widget.existing)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(l.remove),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(l.apply),
        ),
      ],
    );
  }
}
