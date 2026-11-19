import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/utils/fine_raster.dart';
import 'package:handwriting_app/utils/ink_effects.dart' show decodeInkImage;
import 'package:handwriting_app/view_models/fine_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const base = String.fromEnvironment('LIVE_API_BASE');
  test(
    '真实后端：文本导入、单页/多页 PNG、PDF 与 ZIP',
    () async {
      HttpOverrides.global = null;
      final w = Workspace(api: HandwritingApi(base));
      addTearDown(w.dispose);
      await w.connect();
      expect(w.connected, isTrue, reason: w.error);
      final imported = await w.api.importFile(
        '/api/textfileprocess',
        Upload('flutter-smoke.txt', utf8.encode('你好 Flutter')),
      );
      expect(imported['text'], '你好 Flutter');
      w.text = imported['text'];
      w.settings.values.addAll({
        'font_size': '32',
        'line_spacing': '45',
        'width': '420',
        'height': '320',
        'left_margin': '20',
        'right_margin': '20',
        'top_margin': '20',
        'bottom_margin': '20',
        'strikethrough_probability': '0',
      });
      await w.generate();
      expect(w.error, isEmpty);
      expect(w.pages.single.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      w.settings.fullPreview = true;
      w.settings
        ..paperStyle = PaperStyle.grid
        ..latinFont = 'kalam'
        ..latinDigits = true
        ..latinScale = 115;
      w.text = '第一页 Draft 123\n---\n第二页 Cosine Similarity';
      await w.generate();
      expect(w.error, isEmpty);
      expect(w.pages.length, 2);
      for (final pdf in [true, false]) {
        await w.generate(preview: false, pdf: pdf);
        expect(w.error, isEmpty);
        expect(
          latin1.decode(w.exportBytes!.take(pdf ? 5 : 2).toList()),
          pdf ? '%PDF-' : 'PK',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: base.isEmpty
        ? '通过 --dart-define=LIVE_API_BASE=http://127.0.0.1:5006 启用'
        : false,
  );
  test(
    'Rust exports the exact pixels from the Flutter fine-edit compositor',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final w = Workspace(api: HandwritingApi(base));
      addTearDown(w.dispose);
      await w.initialize();
      expect(w.api.supportsFineEdit, isTrue);
      w.text = 'Wave 中文';
      w.settings.values.addAll({
        'font_size': '28',
        'line_spacing': '38',
        'width': '300',
        'height': '230',
        'left_margin': '20',
        'right_margin': '20',
        'top_margin': '20',
        'bottom_margin': '20',
        'strikethrough_probability': '0',
        'ink_thickness': '0.3',
        'ink_softness': '0.8',
      });
      expect(await w.enterFineEdit(), isTrue, reason: w.error);
      final page = w.inkPages.single!;
      final model = page.fine!;
      w.applyFineEdits(model, [
        (
          id: model.glyphs.first.id,
          dx: 50,
          dy: 53,
          scale: 125,
          angle: -17,
          opacity: 72,
          color: 0xff1240d0,
          thickness: 7,
          warp: null,
          softness: -3,
        ),
      ]);
      final selected = FineSelection()
        ..select(model.glyphs.take(2).map((glyph) => glyph.id));
      final rotated = selected.transform(
        model,
        w.fineAdjustments(model),
        angle: 20,
      );
      expect(rotated, isNotNull);
      w.applyFineEdits(model, rotated!);
      final edits = w.fineAdjustments(model);
      final frame = selected.perspectiveFrame(model, edits)!;
      final tilted = selected.corner(
        model,
        edits,
        frame,
        1,
        const ui.Offset(13, -6),
        const ui.Size(300, 230),
      );
      expect(tilted, isNotNull);
      w.applyFineEdits(model, tilted!.changes);
      expect(w.canFineUndo, isTrue);
      expect(w.previewStale, isFalse);
      final png = await compositeFinePage(
        page,
        w.fineAdjustments(model),
        w.settings.inkLook,
      );
      final image = await decodeInkImage(png);
      addTearDown(image.dispose);
      final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      expect(
        await w.generate(preview: false, pdf: true),
        isTrue,
        reason: w.error,
      );
      final pdf = w.exportBytes!;
      final structure = latin1.decode(pdf);
      final tag = structure.indexOf('/Subtype /Image');
      final start = structure.indexOf('\nstream\n', tag) + 8;
      final end = structure.indexOf('\nendstream', start);
      expect(structure.substring(tag, start), contains('/FlateDecode'));
      final pixels = zlib.decode(pdf.sublist(start, end));
      final rgb = [
        for (var i = 0; i < raw.length; i++)
          if (i % 4 != 3) raw[i],
      ];
      expect(pixels, orderedEquals(rgb));
    },
    skip: base.isEmpty ? 'Requires the local Rust engine' : false,
  );
}
