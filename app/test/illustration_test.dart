import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/utils/image_data.dart';
import 'package:handwriting_app/utils/image_markers.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('marker occurrences are exact, legacy compatible and collision safe', () {
    const text =
        '![插图 1|75%] ![插图 10] ![图|250%](img:2) ![插图 #3|900%] ![插图 4](https://example.com/a.png)';
    final markers = illustrationMarkers(text);
    expect(markers.map((m) => m.id), ['1', '10', '2', '3']);
    expect(markers.map((m) => m.scale), [75, 50, 250, 700]);
    expect(
      text.substring(markers[2].start, markers[2].end),
      '![图|250%](img:2)',
    );
    expect(nextIllustrationId({'bad': 'x', '5': 'x'}, text), '4');
    final images = {'bad': 'invalid', '1': 'old'};
    expect(
      collapseImages('![图](data:image/png;base64,YQ==)', images),
      '![插图 2]',
    );
    expect(
      collapseImages('![图|75%](data:image/png;base64,YQ==)', images),
      '![插图 2|75%]',
    );
  });

  testWidgets('normalization validates, downsizes and preserves transparency', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await expectLater(
        prepareIllustration(Uint8List(0)),
        throwsFormatException,
      );
      await expectLater(
        prepareIllustration(Uint8List(12 * 1024 * 1024 + 1)),
        throwsFormatException,
      );
      await expectLater(
        prepareIllustration(Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 5, 5),
        Paint()..color = Colors.black,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(2400, 12);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final normalized = await prepareIllustration(data!.buffer.asUint8List());
      expect(normalized, startsWith('data:image/png;base64,'));
      final codec = await ui.instantiateImageCodec(
        decodeImageData(normalized)!,
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 2048);
      expect(frame.image.height, 10);
      frame.image.dispose();
      codec.dispose();
    });
  });

  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets(
      'phone ${locale.languageCode} edits one occurrence, cancels, removes missing image',
      (tester) async {
        tester.view.physicalSize = const Size(375, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // Readable data URL but corrupt image codec: the editor must stay usable.
        final workspace = Workspace()
          ..text = '![插图 1|50%]\n![插图 1|75%]\n![插图 9]'
          ..images = {
            '1': 'data:image/png;base64,${base64Encode([1, 2, 3])}',
          };
        addTearDown(workspace.dispose);
        await tester.pumpWidget(
          HandwritingApp(locale: locale, workspace: workspace),
        );
        await tester.pumpAndSettle();
        final markers = illustrationMarkers(workspace.text);
        final second = find.byKey(ValueKey('illustration-${markers[1].start}'));
        await tester.ensureVisible(second);
        await tester.pumpAndSettle();
        await tester.tap(second);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('75%'), findsOneWidget);
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('illustration-scale')),
        );
        slider.onChanged!(120);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('illustration-apply')));
        await tester.pumpAndSettle();
        expect(workspace.text, '![插图 1|50%]\n![插图 1|120%]\n![插图 9]');
        // Missing bytes are still visible and removable instead of a hidden marker.
        final missing = illustrationMarkers(workspace.text).last;
        final missingButton = find.byKey(
          ValueKey('illustration-${missing.start}'),
        );
        await tester.ensureVisible(missingButton);
        await tester.pumpAndSettle();
        await tester.tap(missingButton);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('illustration-apply')),
              )
              .onPressed,
          isNull,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(AlertDialog)),
        )!;
        await tester.tap(find.text(l.cancel));
        await tester.pumpAndSettle();
        expect(workspace.text, contains('![插图 9]'));
        await tester.tap(missingButton);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('illustration-remove')));
        await tester.pumpAndSettle();
        expect(workspace.text, '![插图 1|50%]\n![插图 1|120%]\n');
        expect(workspace.images.containsKey('1'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
