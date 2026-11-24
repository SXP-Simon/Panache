import 'dart:ui';

import 'pdf_pages.dart';

typedef PdfPageWriting = ({
  List<PdfWritingBox> boxes,
  String font,
  Color ink,
  bool needsReview,
});

/// Assemble pages in source order. The caller owns navigation, progress,
/// confirmation of questionable pages and the destination of the finished PDF.
Future<({PdfPageExport document, int reviewCount})?> assembleWritingPdf({
  required PdfSourcePage current,
  required Future<PdfSourcePage> Function(int index) readPage,
  required PdfPageWriting Function(PdfSourcePage page) writingFor,
  required bool Function() isActive,
  required void Function(int pageNumber) onPageStarted,
}) async {
  final document = PdfPageExport();
  var reviewCount = 0;
  for (var index = 0; index < current.count; index++) {
    if (!isActive()) return null;
    onPageStarted(index + 1);
    final page = index == current.index ? current : await readPage(index);
    if (!isActive()) return null;
    final writing = writingFor(page);
    if (writing.needsReview) reviewCount++;
    final image = writing.boxes.isEmpty
        ? page.paper
        : await renderPdfWritingPage(
            page,
            writing.boxes,
            writing.font,
            writing.ink,
          );
    await document.add(page, image);
  }
  return (document: document, reviewCount: reviewCount);
}
