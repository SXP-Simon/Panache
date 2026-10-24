import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/screens/workbench.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/widgets/workbench_settings.dart';

class GalleryApi extends HandwritingApi {
  GalleryApi(this.measurements) : super('local://paper-gallery');
  final Map<String, dynamic> measurements;
  @override
  Future<Map<String, dynamic>> importFile(String path, Upload file) async =>
      measurements;
}

void main() {
  final gallery = Platform.environment['PANACHE_PAPER_GALLERY'];
  for (final brightness in Brightness.values) {
    testWidgets(
      'paper identification and rendered preview ${brightness.name}',
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
        final measurements = jsonDecode(
          File('$gallery/tilted-measurements.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        final workspace =
            Workspace(
                api: GalleryApi(measurements),
                settingsFactory: Settings.notebook,
              )
              ..background = Upload(
                '倾斜作业纸.png',
                File('$gallery/tilted-before.png').readAsBytesSync(),
              )
              ..fonts = ['云烟体.ttf']
              ..connected = true
              ..initialized = true;
        workspace.settings.font = '云烟体.ttf';
        addTearDown(workspace.dispose);
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
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(workspace.background!.bytes),
            tester.element(find.byType(Workbench)),
          ),
        );
        await tester.tap(find.text('纸张'));
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(WorkbenchSettings),
              matching: find.byType(Scrollable),
            )
            .first;
        final identify = find.byKey(const ValueKey('identify-paper'));
        await tester.scrollUntilVisible(identify, 150, scrollable: scrollable);
        await tester.pumpAndSettle();
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

        await tester.drag(scrollable, const Offset(0, 200));
        await tester.pumpAndSettle();
        await capture('identify');
        await tester.runAsync(() async {
          await tester.tap(identify);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await tester.pumpAndSettle();
        expect(workspace.background!.name, 'aligned-paper.png');
        expect(workspace.backgroundRuled, isTrue);
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(workspace.background!.bytes),
            tester.element(find.byType(Workbench)),
          ),
        );
        await tester.pumpAndSettle();
        await capture('aligned-background');
        await tester.scrollUntilVisible(identify, 150, scrollable: scrollable);
        await tester.pumpAndSettle();
        await capture('aligned-settings');
        workspace.pages = <Uint8List>[
          File('$gallery/tilted-rendered-1.png').readAsBytesSync(),
        ];
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(workspace.pages.single),
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
