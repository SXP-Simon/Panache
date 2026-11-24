import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/screens/pdf_workbench.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/pdf_pages.dart';

import 'pdf_workbench_test.dart' show host, sourceJson;

PdfSourcePage _page(int index, {List<String> warnings = const []}) {
  final source = sourceJson(index)
    ..['pageWidthPt'] = index == 0 ? 150 : 180
    ..['warnings'] = warnings;
  return PdfSourcePage.fromJson(source, index);
}

Future<void> _open(
  WidgetTester tester, {
  required Future<PdfSourcePage> Function(int) fetch,
  required Future<void> Function(Uint8List) save,
}) async {
  final workbench = PdfWorkbench(
    file: Upload('worksheet.pdf', Uint8List(0)),
    mode: PdfImportMode.fill,
    fetch: fetch,
    loadFont: () async => 'Ahem',
    ink: Colors.black,
    save: save,
  );
  await tester.pumpWidget(
    host(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => workbench),
            ),
            child: const Text('Open worksheet'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open worksheet'));
  await tester.pumpAndSettle();
}

Future<void> _start(WidgetTester tester) async {
  await tester.runAsync(() => tester.tap(find.text('Export PDF')));
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 120 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
}

void _checkPageOrder(Uint8List bytes) {
  final pdf = latin1.decode(bytes);
  final mediaBoxes = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+(\d+)\s+(\d+)\s*\]')
      .allMatches(pdf)
      .map((box) => [box.group(1), box.group(2)]);
  expect(mediaBoxes.toList(), [
    ['150', '200'],
    ['180', '200'],
  ]);
}

void main() {
  testWidgets(
    'clean export reuses the displayed page and saves in source order',
    (tester) async {
      final reads = <int>[];
      final saves = <Uint8List>[];
      await _open(
        tester,
        fetch: (i) async {
          reads.add(i);
          return _page(i, warnings: const ['unrelated_to_fill']);
        },
        save: (data) async => saves.add(data),
      );
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      await _start(tester);
      await _until(tester, () => saves.isNotEmpty);
      expect(reads, [0, 1]);
      expect(saves, hasLength(1));
      _checkPageOrder(saves.single);
      expect(tester.takeException(), isNull);
    },
  );

  for (final accept in [false, true]) {
    testWidgets(
      'review counts affected pages and obeys ${accept ? 'confirmation' : 'rejection'}',
      (tester) async {
        final saves = <Uint8List>[];
        await _open(
          tester,
          fetch: (i) async => _page(
            i,
            warnings: i == 1
                ? const ['partial_render', 'partial_render']
                : const [],
          ),
          save: (data) async => saves.add(data),
        );
        await _start(tester);
        await _until(
          tester,
          () => find.text('Review before exporting').evaluate().isNotEmpty,
        );
        expect(find.textContaining('1 page(s)'), findsOneWidget);
        expect(saves, isEmpty);
        await tester.runAsync(
          () => tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text(accept ? 'Export PDF' : 'Cancel'),
            ),
          ),
        );
        if (accept) {
          await _until(tester, () => saves.isNotEmpty);
          _checkPageOrder(saves.single);
        }
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Export PDF'),
              )
              .onPressed,
          isNotNull,
        );
        expect(saves.length, accept ? 1 : 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a failed page read offers the localized error and allows retry',
    (tester) async {
      var fail = true;
      final saves = <Uint8List>[];
      await _open(
        tester,
        fetch: (i) async {
          if (i == 1 && fail) {
            throw ApiException('read failed', code: 'invalid_document');
          }
          return _page(i);
        },
        save: (data) async => saves.add(data),
      );
      await _start(tester);
      await _until(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      expect(
        find.textContaining('This PDF could not be read.'),
        findsOneWidget,
      );
      expect(saves, isEmpty);
      await tester.runAsync(
        () => tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Close'),
          ),
        ),
      );
      await _until(
        tester,
        () =>
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Export PDF'),
                )
                .onPressed !=
            null,
      );
      await tester.pumpAndSettle();
      fail = false;
      await _start(tester);
      await _until(tester, () => saves.isNotEmpty);
      _checkPageOrder(saves.single);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing the workbench discards a pending warned page', (
    tester,
  ) async {
    final delayed = Completer<PdfSourcePage>();
    final reads = <int>[];
    final saves = <Uint8List>[];
    await _open(
      tester,
      fetch: (i) async {
        reads.add(i);
        return i == 0 ? _page(0) : delayed.future;
      },
      save: (data) async => saves.add(data),
    );
    await _start(tester);
    await _until(tester, () => reads.length == 2);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Open worksheet'), findsOneWidget);
    delayed.complete(_page(1, warnings: const ['partial_render']));
    await tester.pumpAndSettle();
    expect(reads, [0, 1]);
    expect(saves, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
