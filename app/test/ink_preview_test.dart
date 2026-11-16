import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/ink_page.dart';
import 'package:handwriting_app/utils/ink_effects.dart';
import 'package:handwriting_app/widgets/workbench_preview.dart';

Future<Uint8List> png(void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(80, 120);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('press-and-drag reshapes and recolors only the ink image', (
    tester,
  ) async {
    final paper = (await tester.runAsync(
      () => png((canvas) {
        canvas.drawColor(Colors.white, BlendMode.src);
        canvas.drawRect(
          const Rect.fromLTWH(0, 15, 80, 2),
          Paint()..color = const Color(0xff544635),
        );
      }),
    ))!;
    final ink = (await tester.runAsync(
      () => png((canvas) {
        canvas.drawRect(
          const Rect.fromLTWH(30, 40, 12, 24),
          Paint()..color = Colors.black,
        );
      }),
    ))!;
    final pages = [paper];
    final layers = [InkPage(paper, ink)];
    var look = defaultInkLook;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, update) => WorkbenchPreview(
              pages: pages,
              inkPages: layers,
              inkLook: look,
              onInkChanged: (value) => update(() => look = value),
              page: 0,
              version: '',
              locked: false,
              onPageChanged: (_) {},
              onSaveImage: () {},
            ),
          ),
        ),
      ),
    );

    final overlay = find.byWidgetPredicate(
      (widget) =>
          widget is RawImage && widget.colorBlendMode == BlendMode.srcIn,
    );
    RawImage current() => tester.widget<RawImage>(overlay);
    Future<void> waitForMask([ui.Image? previous]) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (overlay.evaluate().isNotEmpty && current().image != previous) {
          return;
        }
      }
      fail('Ink mask did not update while dragging');
    }

    await waitForMask();
    final original = current().image;
    await tester.tap(find.byKey(const ValueKey('preview-ink-effects')));
    await tester.pumpAndSettle();

    Future<TestGesture> drag(String key, double fraction) async {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      final gesture = await tester.startGesture(rect.center);
      await tester.pump();
      await gesture.moveTo(
        Offset(rect.left + rect.width * fraction, rect.center.dy),
      );
      await tester.pump();
      return gesture;
    }

    final fade = await drag('ink-opacity', .43);
    expect(look.opacity, inInclusiveRange(35, 49));
    expect(current().color!.a, closeTo(look.opacity / 100, .001));
    expect(current().image, same(original));
    await fade.up();

    final thicken = await drag('ink-thickness', .98);
    expect(look.thickness, 2);
    await waitForMask(original);
    final thick = current().image;
    await thicken.up();

    final soften = await drag('ink-softness', .98);
    expect(look.softness, 2);
    await waitForMask(thick);
    await soften.up();
    await tester.enterText(
      find.byKey(const ValueKey('preview-ink-color')),
      '#254587',
    );
    await tester.pump();
    expect(current().color!.r, closeTo(37 / 255, .001));

    final result = (await tester.runAsync(() async {
      final bytes = await compositeInkPage(layers.single, look);
      final image = await decodeInkImage(bytes);
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      } finally {
        image.dispose();
      }
    }))!;
    expect(result.getUint32((15 * 80 + 5) * 4), 0x544635ff);
    expect(result.getUint32(0), 0xffffffff);
    final inkPixel = (50 * 80 + 35) * 4;
    for (final (index, color) in [37, 69, 135].indexed) {
      final alpha = (255 * look.opacity / 100).round();
      final expected = (255 * (255 - alpha) + color * alpha + 127) ~/ 255;
      expect(result.getUint8(inkPixel + index), closeTo(expected, 2));
    }
  });
}
