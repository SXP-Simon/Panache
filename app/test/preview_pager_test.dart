import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/widgets/preview_pager.dart';
import 'package:handwriting_app/widgets/workbench_preview.dart';

Uint8List picture() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAFAAAAB4CAIAAADqjOKhAAAAnElEQVR4nO3PAQ0AIAzAsPs3DS5OMloF25zPzOuAbYbrDNcZrjNcZ7jOcJ3hOsN1husM1xmuM1xnuM5wneE6w3WG6wzXGa4zXGe4znCd4TrDdYbrDNcZrjNcZ7jOcJ3hOsN1husM1xmuM1xnuM5wneE6w3WG6wzXGa4zXGe4znCd4TrDdYbrDNcZrjNcZ7jOcJ3hOsN1husM1xmuu+m6FhEStfWXAAAAAElFTkSuQmCC',
);

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'reader zooms at the pointer, drags and resets (reduce=$reduced)',
      (tester) async {
        final pages = [picture(), picture()];
        var page = 0;
        final owner = Object();
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(disableAnimations: reduced),
                child: StatefulBuilder(
                  builder: (_, update) => PreviewPager(
                    pages: pages,
                    page: page,
                    heroOwner: owner,
                    readerMode: true,
                    onPageChanged: (value) => update(() => page = value),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final canvas = find.byKey(const ValueKey('reader-canvas')).first;
        TransformationController transform() =>
            tester.widget<InteractiveViewer>(canvas).transformationController!;
        final origin = tester.getTopLeft(canvas);
        final point = tester.getCenter(canvas) + const Offset(40, 20);
        final shortDrag = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await shortDrag.moveBy(const Offset(6, 4));
        await tester.pump();
        expect(transform().value.entry(0, 3), closeTo(6, .001));
        expect(transform().value.entry(1, 3), closeTo(4, .001));
        await shortDrag.up();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
        await tester.pumpAndSettle();
        final before = transform().toScene(point - origin);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: point,
            scrollDelta: const Offset(0, -140),
          ),
        );
        await tester.pumpAndSettle();
        expect(transform().value.getMaxScaleOnAxis(), greaterThan(1));
        final after = transform().toScene(point - origin);
        expect((after - before).distance, lessThan(.001));
        final translation = transform().value.getTranslation().clone();
        final mouse = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await mouse.moveBy(const Offset(30, 20));
        await tester.pump();
        await mouse.moveBy(const Offset(90, 60));
        await tester.pump(const Duration(milliseconds: 300));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(
          (transform().value.getTranslation() - translation).length,
          greaterThan(50),
        );
        expect(page, 0);
        await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
        await tester.pumpAndSettle();
        expect(transform().value, Matrix4.identity());
        await tester.tap(find.byKey(const ValueKey('reader-zoom-out')));
        await tester.pumpAndSettle();
        expect(transform().value.getMaxScaleOnAxis(), lessThan(1));
        await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
        await tester.pumpAndSettle();
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(transform().value.getMaxScaleOnAxis(), closeTo(2.5, .001));
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(transform().value, Matrix4.identity());
        await tester.tap(find.byKey(const ValueKey('reader-zoom-in')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preview-next')));
        await tester.pumpAndSettle();
        expect(page, 1);
        expect(find.text('100%'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reader tools fit a narrow phone and pinch reserves the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pages = [picture(), picture()];
    var page = 0;
    final owner = Object();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, update) => PreviewPager(
              pages: pages,
              page: page,
              heroOwner: owner,
              readerMode: true,
              onPageChanged: (value) => update(() => page = value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final canvas = find.byKey(const ValueKey('reader-canvas')).first;
    final center = tester.getCenter(canvas);
    final first = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    await first.moveBy(const Offset(-20, 0));
    await second.moveBy(const Offset(20, 0));
    await tester.pump();
    await first.moveBy(const Offset(-35, 0));
    await second.moveBy(const Offset(35, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InteractiveViewer>(canvas)
          .transformationController!
          .value
          .getMaxScaleOnAxis(),
      greaterThan(1),
    );
    expect(page, 0);
    await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
    await tester.pumpAndSettle();
    await tester.drag(canvas, const Offset(-260, 0));
    await tester.pumpAndSettle();
    expect(page, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('click opens viewer, copy uses viewed page, save is retained', (
    tester,
  ) async {
    final pages = [picture(), picture()];
    Uint8List? copied;
    var saved = 0;
    var page = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, update) => WorkbenchPreview(
              pages: pages,
              page: page,
              version: '',
              locked: false,
              onPageChanged: (value) => update(() => page = value),
              onSaveImage: () => saved++,
              copyImage: (bytes) async => copied = bytes,
            ),
          ),
        ),
      ),
    );
    for (final bytes in pages) {
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(bytes),
          tester.element(find.byType(WorkbenchPreview)),
        ),
      );
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save current image'));
    expect(saved, 1);
    await tester.tap(find.byType(Image).first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-preview')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('copy-preview-image')));
    await tester.pumpAndSettle();
    expect(copied, same(pages.first));
    expect(saved, 1);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-preview')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-next')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).last, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-preview-image')));
    await tester.pumpAndSettle();
    expect(copied, same(pages.last));
    expect(find.text('Image copied to clipboard'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save current image'));
    expect(saved, 2);
    expect(page, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press offers copy and failed writes give honest feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkbenchPreview(
            pages: [picture()],
            page: 0,
            version: '',
            locked: false,
            onPageChanged: (_) {},
            onSaveImage: () {},
            copyImage: (_) async => throw StateError('clipboard unavailable'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image).first);
    await tester.runAsync(
      () => precacheImage(
        image.image,
        tester.element(find.byType(WorkbenchPreview)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-preview')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('copy-preview-image')));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not copy the image. Please retry or use Save image.'),
      findsOneWidget,
    );
    expect(find.text('Image copied to clipboard'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'swipe and button navigation share the page (reduce=$reduced)',
      (tester) async {
        final pages = List.generate(3, (_) => picture());
        var page = 0;
        final owner = Object();
        var opened = 0;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: StatefulBuilder(
                builder: (_, update) => PreviewPager(
                  pages: pages,
                  page: page,
                  heroOwner: owner,
                  onPageChanged: (value) => update(() => page = value),
                  onOpen: () => opened++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('preview-pager')),
          const Offset(-650, 0),
        );
        await tester.pumpAndSettle();
        expect(page, 1);
        expect(opened, 0);
        await tester.tap(find.byKey(const ValueKey('preview-next')));
        await tester.pumpAndSettle();
        expect(page, 2);
        expect(find.text('3 / 3'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('preview-next')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('preview-previous')));
        await tester.pumpAndSettle();
        expect(page, 1);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('page feedback never takes control from a held finger', (
    tester,
  ) async {
    final pages = List.generate(2, (_) => picture());
    var page = 0;
    final owner = Object();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StatefulBuilder(
          builder: (_, update) => PreviewPager(
            pages: pages,
            page: page,
            heroOwner: owner,
            onPageChanged: (value) => update(() => page = value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final view = find.byType(PageView);
    final width = tester.getSize(view).width;
    final gesture = await tester.startGesture(tester.getCenter(view));
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(Offset(-width * .7, 0));
    await tester.pump();
    await tester.pump();
    expect(page, 1);
    final controller = tester.widget<PageView>(view).controller!;
    final held = controller.page!;
    expect(held, inExclusiveRange(.5, 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.page, closeTo(held, .0001));
    await gesture.moveBy(Offset(width * .7, 0));
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an old full screen viewer cannot select a new result page', (
    tester,
  ) async {
    var pages = List.generate(2, (_) => picture());
    var page = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return WorkbenchPreview(
                pages: pages,
                page: page,
                version: '',
                locked: false,
                onPageChanged: (value) => setState(() => page = value),
                onSaveImage: () {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('expand-preview')));
    await tester.pumpAndSettle();
    update(() => pages = [picture()]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-next')).last);
    await tester.pumpAndSettle();
    expect(page, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1 / 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zoom reserves dragging for the image until fit page is chosen', (
    tester,
  ) async {
    final pages = List.generate(2, (_) => picture());
    var page = 0;
    final owner = Object();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StatefulBuilder(
          builder: (_, update) => PreviewPager(
            pages: pages,
            page: page,
            heroOwner: owner,
            onPageChanged: (value) => update(() => page = value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final image = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer).first,
    );
    image.transformationController!.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(page, 0);
    await tester.tap(find.byKey(const ValueKey('preview-reset-zoom')));
    await tester.pumpAndSettle();
    expect(image.transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.drag(find.byType(PageView), const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(page, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing results while paging clamps to the new document', (
    tester,
  ) async {
    var pages = List.generate(3, (_) => picture());
    var page = 0;
    final owner = Object();
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return PreviewPager(
              pages: pages,
              page: page,
              heroOwner: owner,
              onPageChanged: (value) => setState(() => page = value),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => page = 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    update(() {
      pages = [picture()];
      page = 0;
    });
    await tester.pumpAndSettle();
    expect(find.text('1 / 1'), findsOneWidget);
    expect(page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'full screen returns to the selected page and clears its flight',
    (tester) async {
      final pages = List.generate(2, (_) => picture());
      var page = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, update) => WorkbenchPreview(
                pages: pages,
                page: page,
                version: '',
                locked: false,
                onPageChanged: (value) => update(() => page = value),
                onSaveImage: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('expand-preview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fullscreen-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preview-next')).last);
      await tester.pumpAndSettle();
      expect(page, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fullscreen-preview')), findsNothing);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
