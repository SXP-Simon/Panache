import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'api.dart';

enum PdfImportMode { text, layout, fill }

class PdfWritingBox {
  const PdfWritingBox(this.rect, this.text, {this.wrap = false});
  final Rect rect;
  final String text;
  final bool wrap;
}

class PdfSourcePage {
  const PdfSourcePage({
    required this.index,
    required this.count,
    required this.size,
    required this.points,
    required this.paper,
    required this.lines,
    required this.warnings,
  });
  final int index, count;
  final Size size, points;
  final Uint8List paper;
  final List<PdfWritingBox> lines;
  final List<String> warnings;

  factory PdfSourcePage.fromJson(Map<String, dynamic> json, int requested) {
    double coordinate(dynamic value) {
      if (value is! num || !value.isFinite) {
        throw const FormatException('Invalid PDF coordinate');
      }
      return value.toDouble();
    }

    final size = Size(coordinate(json['width']), coordinate(json['height']));
    final points = Size(
      coordinate(json['pageWidthPt']),
      coordinate(json['pageHeightPt']),
    );
    final count = json['pageCount'];
    if (size.isEmpty ||
        points.isEmpty ||
        size.width * size.height > 12000000 ||
        json['pageIndex'] != requested ||
        count is! int ||
        requested < 0 ||
        requested >= count) {
      throw const FormatException('Invalid PDF page');
    }
    final lines = <PdfWritingBox>[];
    for (final item in json['lines'] as List) {
      final area = Rect.fromLTWH(
        coordinate(item['x']),
        coordinate(item['y']),
        coordinate(item['width']),
        coordinate(item['height']),
      ).intersect(Offset.zero & size);
      final text = item['text'] as String;
      if (!area.isEmpty && text.trim().isNotEmpty) {
        lines.add(PdfWritingBox(area, text));
      }
    }
    return PdfSourcePage(
      index: requested,
      count: count,
      size: size,
      points: points,
      paper: base64Decode(json['backgroundPng'] as String),
      lines: lines,
      warnings: List<String>.from(json['warnings'] as List),
    );
  }
}

final _pdfFonts = <String, Future<void>>{};

Future<String> loadPdfHandwritingFont(Upload? upload, String? selected) async {
  final name = selected ?? '神韵英子楷书.ttf';
  final family = upload == null
      ? 'PanachePDF-$name'
      : 'PanachePDF-${sha256.convert(upload.bytes)}';
  try {
    await _pdfFonts.putIfAbsent(family, () {
      final data = upload == null
          ? rootBundle.load('packages/handwriting_assets/font_assets/$name')
          : Future.value(ByteData.sublistView(upload.bytes));
      return (FontLoader(family)..addFont(data)).load();
    });
  } catch (_) {
    _pdfFonts.remove(family);
    rethrow;
  }
  return family;
}

/// Shared by the interactive page and the exported image. Original lines retain
/// their source bounding boxes; added answers may wrap across multiple lines.
void paintPdfWriting(
  Canvas canvas,
  Iterable<PdfWritingBox> boxes,
  String family,
  Color ink,
) {
  for (final box in boxes) {
    final area = box.rect;
    final height = box.wrap ? math.min(area.height, 32.0) : area.height;
    final painter = TextPainter(
      text: TextSpan(
        text: box.text,
        style: TextStyle(
          fontFamily: family,
          fontFamilyFallback: const ['packages/handwriting_assets/LXGW WenKai'],
          color: ink,
          fontSize: height,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: box.wrap ? area.width : double.infinity);
    if (painter.width > 0 && painter.height > 0) {
      final scale = math.min(
        1.0,
        math.min(area.width / painter.width, area.height / painter.height),
      );
      canvas.save();
      canvas.clipRect(area);
      canvas.translate(
        area.left,
        area.top + (box.wrap ? 0 : (area.height - painter.height * scale) / 2),
      );
      canvas.scale(scale);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }
    painter.dispose();
  }
}

Future<Uint8List> renderPdfWritingPage(
  PdfSourcePage page,
  List<PdfWritingBox> boxes,
  String family,
  Color ink,
) async {
  final codec = await ui.instantiateImageCodec(page.paper);
  try {
    final background = (await codec.getNextFrame()).image;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        background,
        Rect.fromLTWH(
          0,
          0,
          background.width.toDouble(),
          background.height.toDouble(),
        ),
        Offset.zero & page.size,
        Paint(),
      );
      paintPdfWriting(canvas, boxes, family, ink);
      final picture = recorder.endRecording();
      try {
        final output = await picture.toImage(
          page.size.width.round(),
          page.size.height.round(),
        );
        try {
          final bytes = (await output.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          return bytes.buffer.asUint8List(
            bytes.offsetInBytes,
            bytes.lengthInBytes,
          );
        } finally {
          output.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      background.dispose();
    }
  } finally {
    codec.dispose();
  }
}

// Keep compressed image data for every page until the PDF is written. Holding
// raw RGBA surfaces for a large multipage document exhausts mobile memory.
Uint8List _encodePageJpeg(Uint8List png) {
  final decoded = image.decodePng(png);
  if (decoded == null) throw const FormatException('Invalid PDF page image');
  return image.encodeJpg(decoded, quality: 96);
}

class PdfPageExport {
  final _document = pw.Document(creator: 'Panache');
  int _imageBytes = 0;

  Future<void> add(PdfSourcePage page, Uint8List png) async {
    final jpeg = await compute(_encodePageJpeg, png);
    _imageBytes += jpeg.length;
    if (_imageBytes > 96 * 1024 * 1024) {
      throw ApiException('PDF export limit', code: 'pdf_export_limit');
    }
    final image = pw.MemoryImage(jpeg);
    _document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          page.points.width,
          page.points.height,
          marginAll: 0,
        ),
        build: (_) => pw.Image(
          image,
          width: page.points.width,
          height: page.points.height,
          fit: pw.BoxFit.fill,
        ),
      ),
    );
  }

  Future<Uint8List> finish() => _document.save(enableEventLoopBalancing: true);
}
