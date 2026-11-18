import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/fine_edit.dart';
import 'package:handwriting_app/models/ink_page.dart';
import 'package:handwriting_app/utils/ink_effects.dart' show decodeInkImage;
import 'package:handwriting_app/widgets/fine_preview.dart';

Future<Uint8List> _png(Color background, List<Rect> ink, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(background, BlendMode.src);
  for (final rect in ink) {
    canvas.drawRect(rect, Paint()..color = color);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 140);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
  } finally {
    picture.dispose();
    image.dispose();
  }
}

Future<InkPage> _page() async => InkPage(
  await _png(Colors.white, [
    const Rect.fromLTWH(0, 100, 100, 2),
  ], const Color(0xff788088)),
  null,
  fine: FinePage(
    '0' * 64,
    await _png(Colors.black, [
      const Rect.fromLTWH(0, 0, 28, 12),
    ], const Color(0xffff0000)),
    const [
      FineGlyph(1, 24, 36, 12, 12, 0, 0, 48, (start: 0, end: 1)),
      FineGlyph(2, 45, 36, 12, 12, 16, 0, 48, (start: 1, end: 2)),
    ],
  ),
);

void main() {
  for (final touch in [false, true]) {
    testWidgets(
      touch
          ? 'narrow touch box selection and movement'
          : 'mouse selection, live drag and copy',
      (tester) async {
        await tester.binding.setSurfaceSize(
          touch ? const Size(390, 720) : const Size(1024, 780),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final page = (await tester.runAsync(_page))!;
        final edits = <int, FineAdjustment>{};
        Uint8List? copied;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              platform: touch ? TargetPlatform.android : TargetPlatform.windows,
            ),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => RepaintBoundary(
                  key: const ValueKey('test-preview'),
                  child: FinePreview(
                    page: page,
                    look: defaultInkLook,
                    edits: Map.of(edits),
                    toolbar: true,
                    editing: true,
                    onEdit: (values) => update(() {
                      for (final edit in values) {
                        edits[edit.id] = edit;
                      }
                    }),
                    copyImage: (bytes) async => copied = bytes,
                  ),
                ),
              ),
            ),
          ),
        );
        final canvas = find.byKey(const ValueKey('fine-canvas'));
        for (var i = 0; i < 100 && canvas.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(canvas, findsOneWidget);
        final initialPaper = tester.getRect(canvas);

        Offset point(double x, double y) {
          final area = tester.getRect(canvas);
          return area.topLeft +
              Offset(x * area.width / 100, y * area.height / 140);
        }

        final device = touch
            ? PointerDeviceKind.touch
            : PointerDeviceKind.mouse;
        if (!touch) {
          await tester.tapAt(point(30, 42), kind: device);
          await tester.pump();
          expect(find.text('1 selected'), findsOneWidget);
        } else {
          await tester.tap(find.text('Box select'));
          await tester.pump();
        }
        final box = await tester.startGesture(point(16, 29), kind: device);
        await box.moveTo(point(61, 53));
        await tester.pump();
        await box.up();
        await tester.pump();
        expect(find.text('2 selected'), findsOneWidget);
        expect(tester.getRect(canvas), initialPaper);

        if (touch) {
          await tester.tap(find.text('Move'));
          await tester.pump();
        }
        final drag = await tester.startGesture(point(30, 42), kind: device);
        final delta = point(16, 20) - point(0, 0);
        await drag.moveBy(delta);
        await tester.pump();
        expect(edits, isEmpty);
        final moved = point(46, 62);
        final pixel = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('test-preview')),
          );
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final local = boundary.globalToLocal(moved);
            return bytes.getUint8(
              (local.dy.round() * image.width + local.dx.round()) * 4 + 1,
            );
          } finally {
            image.dispose();
          }
        });
        expect(
          pixel,
          lessThan(130),
          reason: 'the moved ink is visible before release',
        );
        await drag.up();
        await tester.pump();
        expect(edits.values.map((edit) => (edit.dx, edit.dy)), [
          (16, 20),
          (16, 20),
        ]);

        if (touch) return;
        await tester.tapAt(
          point(46, 62),
          kind: device,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('copy-preview-image')));
        for (var i = 0; i < 100 && copied == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(copied, isNotNull);
        final colors = await tester.runAsync(() async {
          final image = await decodeInkImage(copied!);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            int red(int x, int y) => bytes.getUint8((y * image.width + x) * 4);
            return [red(30, 42), red(46, 62), red(67, 62), red(5, 100)];
          } finally {
            image.dispose();
          }
        });
        expect(colors, [255, 0, 0, 120]);
      },
    );
  }
}
