import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/workspace_storage.dart';
import 'package:handwriting_app/utils/image_data.dart';
import 'package:handwriting_app/utils/image_markers.dart';
import 'package:handwriting_app/widgets/workbench_settings.dart';

class _MemoryStorage implements WorkspaceStorage {
  final values = <String, String>{};
  @override
  String? read(String key) => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

/// UI smoke tests deliberately do not require a network server or native picker.
class _UiApi extends HandwritingApi {
  _UiApi() : super('local://ui-test');
  @override
  Future<dynamic> getJson(String path) async =>
      path == '/api/fonts_info' ? ['云烟体.ttf'] : {'version': 'ui-test'};
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android illustration editing and unclipped paper labels', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawLine(
      const Offset(2, 2),
      const Offset(30, 20),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 3,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(32, 24);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final source = await prepareIllustration(bytes!.buffer.asUint8List());
    final storage = _MemoryStorage();
    final workspace =
        Workspace(
            api: _UiApi(),
            storage: storage,
            settingsFactory: Settings.notebook,
          )
          ..text = '插图交互检查\n![插图 1|50%]\n![插图 1|75%]\n![插图 9]'
          ..images = {'1': source}
          ..fonts = ['云烟体.ttf']
          ..connected = true
          ..initialized = true;
    workspace.settings.font = '云烟体.ttf';
    addTearDown(workspace.dispose);
    await tester.pumpWidget(HandwritingApp(workspace: workspace));
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    Future<void> screenshot(String name) async {
      final png = await binding.takeScreenshot(name);
      final path = '${Directory.systemTemp.path}/$name.png';
      await File(path).writeAsBytes(png, flush: true);
      // Integration output is also available in the test result data.
      debugPrint('ANDROID_SCREENSHOT:$path');
    }

    AppLocalizations getLabels() => AppLocalizations.of(
      tester.element(find.byKey(const ValueKey('text-editor'))),
    )!;
    var l = getLabels();
    await tester.tap(find.byKey(const ValueKey('app-preferences')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, l.theme));
    await tester.pumpAndSettle();
    await screenshot('android-illustrations-dark');
    final second = illustrationMarkers(workspace.text)[1];
    final secondButton = find.byKey(ValueKey('illustration-${second.start}'));
    await tester.ensureVisible(secondButton);
    await tester.pumpAndSettle();
    await tester.tap(secondButton);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('75%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final sliderFinder = find.byKey(const ValueKey('illustration-scale'));
    await tester.drag(sliderFinder, const Offset(-25, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot('android-illustration-resize');
    await tester.tap(find.text(l.cancel));
    await tester.pumpAndSettle();
    expect(workspace.text, contains('![插图 1|75%]'));
    await tester.tap(secondButton);
    await tester.pump(const Duration(milliseconds: 500));
    tester.widget<Slider>(sliderFinder).onChanged!(120);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('illustration-apply')));
    await tester.pumpAndSettle();
    expect(workspace.text, contains('![插图 1|50%]\n![插图 1|120%]'));
    final missing = illustrationMarkers(workspace.text).last;
    final missingButton = find.byKey(ValueKey('illustration-${missing.start}'));
    await tester.ensureVisible(missingButton);
    await tester.pumpAndSettle();
    await tester.tap(missingButton);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('illustration-apply')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('illustration-remove')));
    await tester.pumpAndSettle();
    expect(workspace.text, isNot(contains('![插图 9]')));
    await workspace.persist();
    expect(storage.read('flutter.workspace'), contains('120%'));
    await tester.tap(find.text(l.mobilePaper));
    await tester.pumpAndSettle();
    final settingsView = find.byType(WorkbenchSettings);
    final scrollable = find
        .descendant(of: settingsView, matching: find.byType(Scrollable))
        .first;
    final layout = find.text(l.layout);
    await tester.scrollUntilVisible(layout, 200, scrollable: scrollable);
    await tester.pumpAndSettle();
    // Exercise both transitions, then inspect the first numeric field.
    await tester.tap(layout);
    await tester.pumpAndSettle();
    await tester.tap(layout);
    await tester.pumpAndSettle();
    final field = find.byWidgetPredicate(
      (widget) =>
          widget is TextFormField &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('font_size-'),
    );
    final labeledField = find
        .ancestor(of: field, matching: find.byType(SettingsFieldLabel))
        .first;
    await tester.ensureVisible(labeledField);
    await tester.pumpAndSettle();
    final label = find
        .descendant(
          of: find
              .ancestor(of: field, matching: find.byType(SettingsFieldLabel))
              .first,
          matching: find.byType(Text),
        )
        .first;
    expect(label, findsOneWidget);
    expect(tester.getRect(label).bottom, lessThan(tester.getRect(field).top));
    await screenshot('android-paper-labels-dark');
    expect(tester.takeException(), isNull);
  });
}
