import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/widgets/workbench_preview.dart';
import 'package:integration_test/integration_test.dart';
import 'package:super_clipboard/super_clipboard.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('preview menu writes a real PNG to the system clipboard', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.green, BlendMode.src);
    final drawing = recorder.endRecording();
    final image = await drawing.toImage(80, 120);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    drawing.dispose();
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkbenchPreview(
            pages: [png],
            page: 0,
            version: '',
            locked: false,
            onPageChanged: (_) {},
            onSaveImage: () => saved = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-preview')), findsOneWidget);
    final canvas = find.byKey(const ValueKey('reader-canvas'));
    final transform = tester
        .widget<InteractiveViewer>(canvas)
        .transformationController!;
    final shortDrag = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await shortDrag.moveBy(const Offset(6, 4));
    await tester.pump();
    expect(transform.value.entry(0, 3), closeTo(6, .001));
    expect(transform.value.entry(1, 3), closeTo(4, .001));
    await shortDrag.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-zoom-in')));
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1.5, .001));
    final center = tester.getCenter(canvas);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: center,
        scrollDelta: const Offset(0, -100),
      ),
    );
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1.5));
    final previous = transform.value.getTranslation().clone();
    final mouse = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.moveBy(const Offset(30, 20));
    await tester.pump();
    await mouse.moveBy(const Offset(60, 40));
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      (transform.value.getTranslation() - previous).length,
      greaterThan(30),
    );
    await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
    await tester.pumpAndSettle();
    expect(transform.value, Matrix4.identity());
    await tester.tap(find.byKey(const ValueKey('reader-zoom-out')));
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), lessThan(1));
    await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).last, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-preview-image')));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (find.text('Image copied to clipboard').evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Image copied to clipboard'), findsOneWidget);
    final reader = await SystemClipboard.instance!.read();
    expect(reader.canProvide(Formats.png), isTrue);
    expect(reader.canProvide(Formats.fileUri), isFalse);
    final result = Completer<Uint8List>();
    reader.getFile(Formats.png, (file) async {
      try {
        result.complete(await file.readAll());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }, onError: result.completeError);
    final actual = await result.future.timeout(const Duration(seconds: 15));
    expect(actual, orderedEquals(png));
    expect(saved, isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save current image'));
    expect(saved, isTrue);
  });
}
