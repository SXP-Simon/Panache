import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/screens/dialogs/pdf_import_dialog.dart';
import 'package:handwriting_app/screens/pdf_workbench.dart';
import 'package:handwriting_app/screens/workbench.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/pdf_pages.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/widgets/pdf_writing_surface.dart';

class _Picker extends FilePicker {
  _Picker(this.result);
  final FilePickerResult? result;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return result;
  }
}

class _TextApi extends HandwritingApi {
  _TextApi() : super('local://handwriting');
  @override
  Future<Map<String, dynamic>> importFile(String path, Upload file) async => {
    'text': 'Imported as text',
  };
}

final _blank = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFUlEQVR4nGP8//8/AzbAhFV00EoAAFbUAw037MyjAAAAAElFTkSuQmCC',
);
Map<String, dynamic> sourceJson(int index) => {
  'pageCount': 2,
  'pageIndex': index,
  'width': 300,
  'height': 400,
  'pageWidthPt': 150.0,
  'pageHeightPt': 200.0,
  'backgroundPng': base64Encode(_blank),
  'warnings': [],
  'lines': [
    {'text': 'Left', 'x': 20, 'y': 15, 'width': 90, 'height': 18},
    {'text': 'Right', 'x': 160, 'y': 15, 'width': 90, 'height': 18},
  ],
};

Widget host(
  Widget home, {
  Locale locale = const Locale('en'),
  GlobalKey? capture,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: handwritingTheme(Brightness.light),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (_, child) => RepaintBoundary(key: capture, child: child),
  home: home,
);

Future<void> drawAnswer(
  WidgetTester tester,
  Rect normalized,
  String value,
  String apply,
) async {
  final rect = tester.getRect(find.byKey(const ValueKey('pdf-page-surface')));
  Offset at(Offset normalized) =>
      rect.topLeft +
      Offset(normalized.dx * rect.width, normalized.dy * rect.height);
  final gesture = await tester.startGesture(at(normalized.topLeft));
  await gesture.moveTo(at(normalized.center));
  await gesture.moveTo(at(normalized.bottomRight));
  await gesture.up();
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), value);
  await tester.tap(find.text(apply));
  await tester.pumpAndSettle();
}

Future<void> loadGalleryFonts() async {
  for (final item in [
    ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    (
      'packages/handwriting_assets/LXGW WenKai',
      'packages/handwriting_assets/font_assets/霞鹜文楷.ttf',
    ),
    ('Playfair Display', 'assets/fonts/PlayfairDisplay.ttf'),
  ]) {
    await (FontLoader(item.$1)..addFont(rootBundle.load(item.$2))).load();
  }
}

void main() {
  test('source pages keep physical dimensions, columns and the requested page identity', () {
    final p = PdfSourcePage.fromJson(sourceJson(1), 1);
    expect(p.points, const Size(150, 200));
    expect(p.lines[1].rect.left, 160);
    expect(p.lines[0].rect.top, p.lines[1].rect.top);
    expect(
      () => PdfSourcePage.fromJson(sourceJson(1), 0),
      throwsFormatException,
    );
  });

  test(
    'export produces two flattened PDF pages at their source print size',
    () async {
      final document = PdfPageExport();
      for (var i = 0; i < 2; i++) {
        await document.add(PdfSourcePage.fromJson(sourceJson(i), i), _blank);
      }
      final bytes = await document.finish();
      final pdf = latin1.decode(bytes);
      expect(pdf, startsWith('%PDF-'));
      expect(RegExp(r'/Type\s*/Page\b').allMatches(pdf).length, 2);
      expect(
        RegExp(r'/MediaBox\s*\[\s*0\s+0\s+150\s+200\s*\]')
            .allMatches(pdf)
            .length,
        2,
      );
    },
  );

  testWidgets(
    'PDF importer discloses remote processing before choosing a mode',
    (tester) async {
      PdfImportMode? mode;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => mode = await choosePdfImport(
                  context,
                  'https://render.example',
                ),
                child: const Text('Open PDF'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open PDF'));
      await tester.pumpAndSettle();
      expect(find.textContaining('https://render.example'), findsOneWidget);
      expect(find.text('Extract plain text'), findsOneWidget);
      expect(find.text('Rewrite in the original layout'), findsOneWidget);
      await tester.tap(find.text('Write on the original pages'));
      await tester.pumpAndSettle();
      expect(mode, PdfImportMode.fill);
    },
  );

  testWidgets(
    'answers stay on their own source page and closing protects edits',
    (tester) async {
      await tester.pumpWidget(
        host(
          PdfWorkbench(
            file: Upload('form.pdf', Uint8List(0)),
            mode: PdfImportMode.fill,
            fetch: (i) async => PdfSourcePage.fromJson(sourceJson(i), i),
            loadFont: () async => 'Ahem',
            ink: Colors.black,
            save: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await drawAnswer(
        tester,
        const Rect.fromLTRB(.1, .15, .8, .27),
        'Answer A',
        'Apply',
      );
      List<PdfWritingBox> answers() => tester
          .widget<PdfWritingSurface>(find.byType(PdfWritingSurface))
          .boxes;
      expect(answers().single.text, 'Answer A');
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(answers(), isEmpty);
      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(answers().single.text, 'Answer A');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Close this PDF?'), findsOneWidget);
    },
  );

  final gallery = Platform.environment['PANACHE_PDF_GALLERY'];
  testWidgets(
    'workbench PDF selection offers all modes before plain-text import',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(470, 870);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      FilePicker.platform = _Picker(
        FilePickerResult([
          PlatformFile(
            name: 'lesson.PDF',
            size: 4,
            bytes: Uint8List.fromList([37, 80, 68, 70]),
          ),
        ]),
      );
      addTearDown(() => FilePicker.platform = _Picker(null));
      final workspace = Workspace(api: _TextApi())
        ..connected = true
        ..initialized = true;
      addTearDown(workspace.dispose);
      if (gallery != null) {
        await tester.runAsync(loadGalleryFonts);
      }
      await tester.pumpWidget(
        host(
          Workbench(
            workspace: workspace,
            toggleLocale: () {},
            toggleTheme: () {},
          ),
          locale: const Locale('zh'),
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Workbench)))!;
      await tester.tap(find.byKey(const ValueKey('editor-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, l.importText));
      await tester.pumpAndSettle();
      expect(find.text(l.pdfLayout), findsOneWidget);
      expect(find.text(l.pdfFill), findsOneWidget);
      if (gallery != null) {
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            File('$gallery/ui-import.png')
                .writeAsBytesSync(bytes.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.tap(find.text(l.pdfText));
      await tester.pumpAndSettle();
      expect(workspace.text, 'Imported as text');
      expect(tester.takeException(), isNull);
    },
  );
  for (final mode in [PdfImportMode.layout, PdfImportMode.fill]) {
    testWidgets(
      'render and export actual PDF pages in the ${mode.name} screen',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(920, 960);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final family = await tester.runAsync(() async {
          await loadGalleryFonts();
          return loadPdfHandwritingFont(null, '神韵英子楷书.ttf');
        });
        final capture = GlobalKey();
        var saved = false;
        final sources = List.generate(
          2,
          (i) => PdfSourcePage.fromJson(
            jsonDecode(File('$gallery/${mode.name}-$i.json').readAsStringSync())
                as Map<String, dynamic>,
            i,
          ),
        );
        await tester.pumpWidget(
          host(
            PdfWorkbench(
              file: Upload('叶片的蒸腾作用.pdf', Uint8List(0)),
              mode: mode,
              fetch: (i) async => sources[i],
              loadFont: () async => family!,
              ink: const Color(0xff223e62),
              save: (bytes) async {
                File('$gallery/field-studies-${mode.name}.pdf')
                    .writeAsBytesSync(bytes);
                saved = true;
              },
            ),
            locale: const Locale('zh'),
            capture: capture,
          ),
        );
        await tester.pumpAndSettle();
        if (mode == PdfImportMode.fill) {
          await tester.tap(find.byTooltip('下一页'));
          await tester.pumpAndSettle();
          for (final answer in [
            (const Rect.fromLTRB(.077, .355, .90, .410), '叶片 A 与叶片 B'),
            (const Rect.fromLTRB(.077, .54, .90, .594), '相同光照，分别置于通风处和静止空气中。'),
            (
              const Rect.fromLTRB(.077, .733, .90, .82),
              '通风处的水滴较多。空气流动加快了水分散失。',
            ),
          ]) {
            await drawAnswer(tester, answer.$1, answer.$2, '应用');
          }
        }
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(sources[mode == PdfImportMode.fill ? 1 : 0].paper),
            tester.element(find.byType(PdfWritingSurface)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            File('$gallery/ui-${mode.name}.png')
                .writeAsBytesSync(bytes.buffer.asUint8List());
          } finally {
            image.dispose();
          }
          await tester.tap(find.text('导出 PDF'));
        });
        for (var attempt = 0; attempt < 120; attempt++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (find.text('检查导出页面').evaluate().isNotEmpty) {
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(FilledButton, '导出 PDF').last),
            );
          }
          if (saved) {
            break;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
        }
        expect(saved, isTrue);
        expect(
          File('$gallery/field-studies-${mode.name}.pdf').lengthSync(),
          greaterThan(1500),
        );
        expect(tester.takeException(), isNull);
      },
      skip: gallery == null,
    );
  }
}
