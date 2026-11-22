import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:handwriting_app/widgets/workbench_motion.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/models/fine_edit.dart';
import 'package:handwriting_app/models/fine_transform.dart';
import 'package:handwriting_app/models/ink_page.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/utils/ink_effects.dart' show decodeInkImage;
import 'package:handwriting_app/utils/fine_raster.dart';
import 'package:handwriting_app/view_models/fine_selection.dart';
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
      const Rect.fromLTWH(4, 4, 4, 4),
      const Rect.fromLTWH(20, 4, 4, 4),
    ], const Color(0xffff0000)),
    const [
      FineGlyph(1, 24, 36, 12, 12, 0, 0, 48, (start: 0, end: 1)),
      FineGlyph(2, 45, 36, 12, 12, 16, 0, 48, (start: 1, end: 2)),
    ],
  ),
);

void main() {
  testWidgets(
    'diagram detail hit and whole illustration selection use the atlas groups',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sample = (await tester.runAsync(_page))!;
      final model = FinePage.fromJson({
        'key': '0' * 64,
        'atlas': base64Encode(sample.fine!.atlas),
        'glyphs': [
          [10, 24, 36, 40, 16, 0, 0, 52],
          [11, 42, 36, 12, 12, 16, 0, 48],
        ],
        'illustrations': {
          '10': [10, 11],
        },
      });
      final page = InkPage(sample.paper, null, fine: model);
      final changes = <int, FineAdjustment>{};
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: FinePreview(
              page: page,
              look: defaultInkLook,
              edits: changes,
              copyImage: (_) async {},
              toolbar: true,
              editing: true,
              onEdit: (items) {
                for (final item in items) {
                  changes[item.id] = item;
                }
              },
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
      final rect = tester.getRect(canvas);
      await tester.tapAt(
        rect.topLeft + Offset(48 * rect.width / 100, 42 * rect.height / 140),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(find.text('Diagram detail'), findsOneWidget);
      final all = find.byKey(const ValueKey('fine-select-drawing'));
      await tester.ensureVisible(all);
      await tester.tap(all);
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
    },
  );
  testWidgets(
    'phone fullscreen keeps the same canvas, selection and history',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 840);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);

      final page = (await tester.runAsync(_page))!;
      final workspace =
          Workspace(
              api: HandwritingApi('local://test-engine')
                ..supportsFineEdit = true,
            )
            ..text = '字迹'
            ..initialized = true
            ..fineEnabled = true;
      workspace.generation
        ..pages = [page.paper]
        ..inkPages = [page]
        ..previewRevision = workspace.editRevision;
      addTearDown(workspace.dispose);

      Finder keyed(String value) => find.byKey(ValueKey(value));
      await tester.pumpWidget(
        HandwritingApp(locale: const Locale('en'), workspace: workspace),
      );
      await tester.tap(keyed('open-preview'));
      await tester.pump();
      await tester.pump(WorkbenchMotion.pane);
      expect(keyed('expand-preview'), findsOneWidget);
      expect(keyed('fullscreen-fine-edit'), findsNothing);

      await tester.tap(keyed('fine-edit-toggle'));
      final canvas = keyed('fine-canvas');
      for (var i = 0; i < 100 && canvas.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(canvas, findsOneWidget);
      Offset point(Offset paperPoint) {
        final box = tester.renderObject<RenderBox>(canvas);
        return box.localToGlobal(paperPoint * (box.size.width / 100));
      }

      final fineState = tester.state(find.byType(FinePreview));
      final normalCanvasHeight = tester
          .getSize(find.byType(InteractiveViewer))
          .height;
      await tester.tapAt(point(const Offset(30, 42)));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(keyed('fullscreen-fine-edit'));
      await tester.pump();
      tester.view.physicalSize = const Size(320, 720);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(FinePreview)), same(fineState));
      expect(
        tester.getSize(find.byType(InteractiveViewer)).height,
        greaterThan(normalCanvasHeight),
      );
      expect(keyed('open-preview'), findsNothing);
      expect(keyed('app-preferences'), findsNothing);
      expect(
        tester.getTopLeft(keyed('exit-fullscreen-fine-edit')).dy,
        greaterThanOrEqualTo(24),
      );
      expect(
        tester.getBottomRight(keyed('fullscreen-fine-tool-move')).dy,
        lessThanOrEqualTo(700),
      );
      expect(keyed('fine-thickness'), findsNothing);

      await tester.tap(keyed('fine-selection-settings'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(keyed('fine-thickness'), findsOneWidget);
      await tester.tap(keyed('fine-selection-settings'));
      await tester.pump();

      await tester.tap(keyed('fullscreen-fine-tool-box'));
      await tester.pump();
      final box = await tester.startGesture(point(const Offset(16, 29)));
      await box.moveTo(point(const Offset(62, 53)));
      await box.up();
      await tester.pump();
      await tester.tap(keyed('fullscreen-fine-tool-perspective'));
      await tester.pump();
      final selection = FineSelection()..select([1, 2]);
      final corner = selection
          .perspectiveFrame(page.fine!, const {})!
          .points
          .first;
      final drag = await tester.startGesture(point(corner));
      await drag.moveTo(point(corner + const Offset(-5, -7)));
      await tester.pump();
      expect(workspace.fineAdjustments(page.fine!), isEmpty);
      await drag.up();
      await tester.pump();
      final edits = workspace.fineAdjustments(page.fine!);
      expect(edits.keys, unorderedEquals([1, 2]));
      expect(workspace.canFineUndo, isTrue);

      final viewer = find.byType(InteractiveViewer);
      final camera = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(camera.value.getMaxScaleOnAxis(), closeTo(1.25, .001));

      tester.view.physicalSize = const Size(760, 340);
      await tester.pumpAndSettle();
      expect(keyed('exit-fullscreen-fine-edit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomRight(keyed('fullscreen-fine-tool-move')).dy,
        lessThanOrEqualTo(320),
      );
      tester.view.physicalSize = const Size(390, 840);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(keyed('exit-fullscreen-fine-edit'), findsNothing);
      expect(keyed('fullscreen-fine-edit'), findsOneWidget);
      expect(keyed('open-preview'), findsOneWidget);
      expect(tester.state(find.byType(FinePreview)), same(fineState));
      expect(workspace.fineAdjustments(page.fine!), edits);
      expect(camera.value.getMaxScaleOnAxis(), closeTo(1.25, .001));

      await tester.tap(keyed('fullscreen-fine-edit'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('fine-undo'));
      await tester.pump();
      expect(workspace.fineAdjustments(page.fine!), isEmpty);
      await tester.tap(keyed('exit-fullscreen-fine-edit'));
      await tester.pumpAndSettle();
      expect(keyed('open-preview'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  test('four corner map sends each point to its exact destination', () {
    const source = [
      Offset(12, 20),
      Offset(90, 25),
      Offset(110, 100),
      Offset(20, 90),
    ];
    const target = [
      Offset(16, 55),
      Offset(130, 10),
      Offset(106, 111),
      Offset(10, 98),
    ];
    final mapping = fineQuadTransform(source, target)!;
    for (var i = 0; i < source.length; i++) {
      final at =
          mapFinePoint(mapping.matrix, source[i] - mapping.origin) +
          mapping.origin;
      expect((at - target[i]).distance, lessThan(1e-9));
    }
    expect(
      fineQuadTransform(source, [target[0], target[2], target[1], target[3]]),
      isNull,
    );
  });
  test('group rotates centers together, then perspective and JSON preserve the group', () {
    final glyphs = [
      const FineGlyph(1, 0, 0, 10, 10, 0, 0, 10, null),
      const FineGlyph(2, 40, 0, 10, 10, 0, 0, 10, null),
      const FineGlyph(3, 0, 40, 10, 10, 0, 0, 50, null),
      const FineGlyph(4, 40, 40, 10, 10, 0, 0, 50, null),
    ];
    final page = FinePage('0' * 64, Uint8List(0), glyphs);
    final selection = FineSelection()..select([1, 2, 3, 4]);
    final rotated = {
      for (final edit in selection.transform(page, {}, angle: 30)!)
        edit.id: edit,
    };
    final first = FinePose(glyphs[0], rotated[1]).center;
    final second = FinePose(glyphs[1], rotated[2]).center;
    expect(second.dy - first.dy, closeTo(20, 1e-8));
    expect((second - first).distance, closeTo(40, 1e-8));
    final tilted = {
      for (final edit in selection.transform(page, {}, horizontal: 24)!)
        edit.id: edit,
    };
    double height(int first, int last) =>
        FinePose(glyphs[last - 1], tilted[last]).center.dy -
        FinePose(glyphs[first - 1], tilted[first]).center.dy;
    expect(height(1, 3), greaterThan(height(2, 4)));
    expect(
      FineEdits.fromJson(FineEdits(page.key, tilted).toJson()).glyphs,
      tilted,
    );
  });
  for (final touch in [false, true]) {
    testWidgets(
      touch
          ? 'narrow touch lasso selection and movement'
          : 'mouse selection, live drag and copy',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = touch
            ? const Size(390, 720)
            : const Size(1024, 665);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final page = (await tester.runAsync(_page))!;
        final edits = <int, FineAdjustment>{};
        final inspector = touch ? null : FineInspectorSlot();
        addTearDown(() => inspector?.dispose());
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
              body: Padding(
                padding: const EdgeInsets.fromLTRB(0, 120, 0, 104),
                child: StatefulBuilder(
                  builder: (context, update) => Row(
                    children: [
                      if (inspector != null)
                        SizedBox(
                          width: 360,
                          child: ValueListenableBuilder(
                            valueListenable: inspector,
                            builder: (context, value, _) =>
                                value?.hasSelection == true
                                ? value!.build(context)
                                : const SizedBox.shrink(),
                          ),
                        ),
                      Expanded(
                        child: RepaintBoundary(
                          key: const ValueKey('test-preview'),
                          child: FinePreview(
                            page: page,
                            look: defaultInkLook,
                            edits: Map.of(edits),
                            toolbar: true,
                            editing: true,
                            inspector: inspector,
                            onEdit: (values) => update(() {
                              for (final edit in values) {
                                edits[edit.id] = edit;
                              }
                            }),
                            copyImage: (bytes) async => copied = bytes,
                          ),
                        ),
                      ),
                    ],
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
        await tester.pump();
        final transform = tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!;
        expect(
          transform.value.getMaxScaleOnAxis(),
          touch ? 1 : greaterThan(1.5),
        );
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
          await tester.pump();
          expect(find.text('1 selected'), findsOneWidget);
        } else {
          await tester.tap(find.text('Lasso'));
          await tester.pump();
        }
        final box = await tester.startGesture(point(16, 34), kind: device);
        if (touch) await box.moveTo(point(61, 34));
        await box.moveTo(point(61, 53));
        if (touch) await box.moveTo(point(16, 53));
        await tester.pump();
        await box.up();
        await tester.pump();
        await tester.pump();
        expect(find.text('2 selected'), findsOneWidget);
        expect(tester.getRect(canvas), initialPaper);
        final reset = find.byKey(const ValueKey('fine-reset'));
        final color = find.byKey(const ValueKey('fine-color'));
        final snap = find.widgetWithText(FilterChip, 'Snap to lines');
        for (final action in [color, snap, reset]) {
          expect(action.hitTestable(), findsOneWidget);
          if (!touch) expect(tester.getRect(action).right, lessThan(360));
        }

        if (touch) {
          await tester.tap(find.text('Move'));
          await tester.pump();
        }
        final drag = await tester.startGesture(point(30, 42), kind: device);
        final delta = point(16, 20) - point(0, 0);
        await drag.moveBy(delta);
        await tester.pump();
        expect(edits, isEmpty);
        Future<int?> greenAt(double x, double y) => tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('test-preview')),
          );
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final local = boundary.globalToLocal(point(x, y));
            return bytes.getUint8(
              (local.dy.round() * image.width + local.dx.round()) * 4 + 1,
            );
          } finally {
            image.dispose();
          }
        });
        expect(
          await greenAt(46, 62),
          lessThan(130),
          reason: 'the moved ink is visible before release',
        );
        await drag.up();
        await tester.pump();
        expect(edits.values.map((edit) => (edit.dx, edit.dy)), [
          (16, 20),
          (16, 20),
        ]);

        if (touch) {
          final mode = find.text('Corner perspective');
          await tester.ensureVisible(mode);
          await tester.pump();
          await tester.tap(mode);
          await tester.pump();
          final selected = FineSelection()..select(edits.keys);
          final frame = selected.perspectiveFrame(page.fine!, edits)!;
          final right = frame.points[1];
          final corner = await tester.startGesture(
            point(right.dx, right.dy),
            kind: device,
          );
          await corner.moveTo(point(right.dx + 8, right.dy + 4));
          await tester.pump();
          expect(edits.values.every((edit) => edit.warp == null), isTrue);
          await corner.up();
          await tester.pump();
          expect(edits.values.every((edit) => edit.warp != null), isTrue);
          return;
        }
        final slider = find.byKey(const ValueKey('fine-thickness'));
        await tester.ensureVisible(slider);
        await tester.pump();
        expect(slider.hitTestable(), findsOneWidget);
        final sliderBox = tester.getRect(slider);
        final stroke = await tester.startGesture(
          sliderBox.center,
          kind: device,
        );
        await stroke.moveTo(sliderBox.centerRight - const Offset(6, 0));
        await tester.pump();
        await tester.pump();
        expect(tester.widget<Slider>(slider).value, greaterThan(0));
        int? edge;
        for (var i = 0; i < 30; i++) {
          await tester.pump();
          edge = await greenAt(43.5, 62.5);
          if (edge != null && edge < 130) break;
        }
        expect(
          edge,
          lessThan(130),
          reason: 'the thicker edge appears before release',
        );
        expect(edits.values.every((edit) => edit.thickness == 0), isTrue);
        await stroke.up();
        await tester.pump();
        expect(edits.values.every((edit) => edit.thickness > 0), isTrue);
        await tester.tapAt(point(67, 62), kind: device);
        await tester.pump();
        await tester.pump();
        expect(find.text('1 selected'), findsOneWidget);
        final softness = find.byKey(const ValueKey('fine-softness'));
        await tester.ensureVisible(softness);
        await tester.pump();
        final softnessBox = tester.getRect(softness);
        expect(softness.hitTestable(), findsOneWidget);
        final soften = await tester.startGesture(
          softnessBox.centerLeft + const Offset(20, 0),
          kind: device,
        );
        await soften.moveTo(softnessBox.center);
        await tester.pump();
        await tester.pump();
        expect(tester.widget<Slider>(softness).value, greaterThan(0));
        await soften.up();
        await tester.pump();
        expect(edits[1]!.softness, 0);
        expect(edits[2]!.softness, greaterThan(0));
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
            return [
              red(30, 42),
              red(43, 62),
              red(46, 62),
              red(67, 62),
              red(5, 100),
            ];
          } finally {
            image.dispose();
          }
        });
        expect(colors, [255, 0, 0, 0, 120]);
        await tester.tap(reset);
        await tester.pump();
        expect(edits[2], defaultFineAdjustment(2));
      },
    );
  }
}
