import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/mobile_api.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('editor-first navigation and real two-page preview', (
    tester,
  ) async {
    final api = await MobileHandwritingApi.bundled();
    final workspace = Workspace(api: api, managedBackend: true);
    addTearDown(workspace.dispose);
    await workspace.initialize();
    workspace.settings.font = workspace.fonts.first;
    workspace.settings.fullPreview = true;
    workspace.settings.values.addAll({
      'width': '420',
      'height': '560',
      'font_size': '28',
      'line_spacing': '42',
      'left_margin': '24',
      'right_margin': '24',
      'top_margin': '24',
      'bottom_margin': '24',
    });
    await tester.pumpWidget(HandwritingApp(workspace: workspace));
    await tester.pumpAndSettle();
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final png = await binding.takeScreenshot(name);
      final path = '${Directory.systemTemp.path}/$name.png';
      await File(path).writeAsBytes(png, flush: true);
      debugPrint('WORKFLOW_SCREENSHOT:$path');
    }

    final editor = find.byKey(const ValueKey('text-editor'));
    const draft = '记录生活中的小事。\n让文字保留手写的温度。\n---\n第二页\nHello Panache';
    await tester.enterText(editor, draft);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final controller = tester.widget<TextField>(editor).controller!;
    controller.selection = const TextSelection.collapsed(offset: 3);
    await capture('panache-editor');
    await tester.tap(find.byKey(const ValueKey('open-paper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const PageStorageKey('settings-paper')), findsOneWidget);
    await capture('panache-paper');
    await tester.tap(find.byKey(const ValueKey('back-to-editor')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(editor).controller, same(controller));
    expect(controller.selection.baseOffset, 3);
    await tester.tap(find.byKey(const ValueKey('generate-preview')));
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (workspace.busy && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
    expect(workspace.busy, isFalse);
    expect(workspace.error, isEmpty);
    expect(workspace.pages, hasLength(2));
    await capture('panache-preview');
    final pager = find.byKey(const ValueKey('preview-pager'));
    final bounds = tester.getRect(pager);
    await tester.timedDragFrom(
      Offset(bounds.right - bounds.width * .1, bounds.center.dy),
      Offset(-bounds.width * .8, 0),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(workspace.page, 1);
    await tester.tap(find.byKey(const ValueKey('expand-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-preview')), findsOneWidget);
    await capture('panache-fullscreen');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('back-to-editor')));
    await tester.pumpAndSettle();
    expect(controller.text, draft);
    expect(tester.takeException(), isNull);
  });
}
