import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/screens/workbench.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/utils/prepare_text.dart';
import 'package:handwriting_app/widgets/workbench_settings.dart';

void main() {
  final gallery = Platform.environment['PANACHE_HOMEWORK_GALLERY'];
  test('prepare shared homework gallery source', () {
    File('$gallery/source-prepared.txt').writeAsStringSync(
      prepareHandwritingText(
        File('$gallery/source-raw.txt').readAsStringSync(),
      ),
    );
  }, skip: gallery == null);
  for (final brightness in Brightness.values) {
    testWidgets(
      'homework preset ${brightness.name} keeps settings and displays generated pages',
      (tester) async {
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
          await (FontLoader('packages/handwriting_assets/LXGW WenKai')..addFont(
                rootBundle.load(
                  'packages/handwriting_assets/font_assets/霞鹜文楷.ttf',
                ),
              ))
              .load();
        });
        final workspace = Workspace(settingsFactory: Settings.notebook)
          ..fonts = ['云烟体.ttf']
          ..connected = true
          ..initialized = true
          ..text = File('$gallery/source-prepared.txt').readAsStringSync();
        workspace.settings.font = '云烟体.ttf';
        workspace.settings.values.addAll({
          'width': '1200',
          'height': '1697',
          'font_size': '46',
          'line_spacing': '82',
          'top_margin': '28',
          'bottom_margin': '64',
          'left_margin': '35',
          'right_margin': '35',
        });
        addTearDown(workspace.dispose);
        final before = Map<String, String>.of(workspace.settings.values);
        final source = workspace.text;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: handwritingTheme(brightness),
            home: RepaintBoundary(
              key: boundary,
              child: Workbench(
                workspace: workspace,
                toggleLocale: () {},
                toggleTheme: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('纸张'));
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(WorkbenchSettings),
              matching: find.byType(Scrollable),
            )
            .first;
        final selector = find.byKey(const ValueKey('layout-style'));
        await tester.scrollUntilVisible(selector, 150, scrollable: scrollable);
        await tester.drag(scrollable, const Offset(0, 80));
        await tester.pumpAndSettle();
        await tester.tap(find.text('作业笔记'));
        await tester.pumpAndSettle();
        expect(workspace.settings.layoutStyle, 'homework');
        expect(workspace.settings.values, before);
        expect(workspace.settings.font, '云烟体.ttf');
        expect(workspace.text, source);
        Future<void> capture(String suffix) async {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('$gallery/flutter-${brightness.name}-$suffix.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('preset');
        await tester.tap(find.text('标准排版'));
        await tester.pumpAndSettle();
        expect(workspace.settings.layoutStyle, 'standard');
        await tester.tap(find.text('作业笔记'));
        await tester.pumpAndSettle();
        workspace.pages = [
          for (final name in ['homework-1.png', 'homework-2.png'])
            File('$gallery/shared/$name').readAsBytesSync(),
        ];
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(workspace.pages.first),
            tester.element(find.byType(Workbench)),
          ),
        );
        workspace.emit();
        await tester.pumpAndSettle();
        await tester.tap(find.text('预览').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture('preview');
        await tester.pumpWidget(const SizedBox());
      },
      skip: gallery == null,
    );
  }
}
