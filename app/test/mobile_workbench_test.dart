import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';

class MobileTestApi extends HandwritingApi {
  MobileTestApi() : super('local://test-engine');
  String? cancelled;
  final terminal = Completer<Map<String, dynamic>>();
  Completer<void>? stoppingGate;
  @override
  Future<String> submit(
    Map<String, String> fields,
    Map<String, Upload> files, {
    String? taskId,
  }) async => 'mobile-task';
  @override
  Future<Map<String, dynamic>> status(String id) => terminal.future;
  @override
  bool get supportsCancel => true;
  @override
  Future<void> cancelTask(String id) async {
    cancelled = id;
    await stoppingGate?.future;
    if (!terminal.isCompleted) terminal.complete({'task_status': 'cancelled'});
  }
}

void main() {
  Future<Workspace> openWorkbench(
    WidgetTester tester, {
    required Size size,
    Locale locale = const Locale('zh'),
    double textScale = 1,
    bool generating = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final workspace = Workspace(api: MobileTestApi())
      ..fonts = ['test.ttf']
      ..text = generating ? 'draft' : '';
    workspace.settings.font = 'test.ttf';
    if (generating) unawaited(workspace.generate());
    addTearDown(workspace.dispose);
    await tester.pumpWidget(
      HandwritingApp(locale: locale, workspace: workspace),
    );
    // Progress indicators intentionally keep animating during generation.
    await tester.pump();
    return workspace;
  }

  AppLocalizations labels(WidgetTester tester) => AppLocalizations.of(
    tester.element(find.byKey(const ValueKey('text-editor'))),
  )!;

  Future<void> waitPreparation(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    await tester.pump();
    while (find
        .byKey(const ValueKey('stop-text-preparation'))
        .evaluate()
        .isNotEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('Text worker did not finish');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 375.0]) {
    for (final locale in [const Locale('zh'), const Locale('en')]) {
      testWidgets(
        'mobile $width ${locale.languageCode} named tools insert a page',
        (tester) async {
          final workspace = await openWorkbench(
            tester,
            size: Size(width, 800),
            locale: locale,
          );
          final l = labels(tester);
          await tester.enterText(
            find.byKey(const ValueKey('text-editor')),
            'First page',
          );
          await tester.tap(find.byKey(const ValueKey('editor-tools')));
          await tester.pumpAndSettle();
          expect(find.text(l.editingToolsHint), findsOneWidget);
          expect(find.widgetWithText(ListTile, l.importText), findsOneWidget);
          expect(find.widgetWithText(ListTile, l.insertImage), findsOneWidget);
          final pageBreak = find.widgetWithText(ListTile, l.pageBreak);
          await tester.ensureVisible(pageBreak);
          await tester.pumpAndSettle();
          expect(find.text(l.pageBreakHelp), findsOneWidget);
          await tester.tap(pageBreak);
          await tester.pumpAndSettle();
          expect(workspace.text, 'First page\n---\n');
          expect(find.byType(BottomSheet), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets(
      'manual spacing survives until Markdown cleanup ${locale.languageCode}',
      (tester) async {
        final workspace = await openWorkbench(
          tester,
          size: const Size(375, 800),
          locale: locale,
        );
        const manual = '### 第一段\n\n---\n\n第二段 \$x^2\$；代码 `x^2`';
        final input = find.byKey(const ValueKey('text-editor'));
        await tester.enterText(input, manual);
        await tester.pumpAndSettle();
        expect(workspace.text, manual);
        expect(tester.widget<TextField>(input).controller!.text, manual);
        final l = labels(tester);
        Future<void> openCleanup() async {
          await tester.tap(find.byKey(const ValueKey('editor-tools')));
          await tester.pumpAndSettle();
          final cleanup = find.widgetWithText(ListTile, l.prepareText);
          expect(find.widgetWithText(ListTile, l.latex), findsNothing);
          expect(find.widgetWithText(ListTile, l.markdown), findsNothing);
          await tester.ensureVisible(cleanup);
          await tester.pumpAndSettle();
          await tester.tap(cleanup);
          await tester.pumpAndSettle();
        }

        await openCleanup();
        await tester.tap(find.widgetWithText(TextButton, l.cancel));
        await tester.pumpAndSettle();
        expect(workspace.text, manual);
        await openCleanup();
        await tester.tap(find.widgetWithText(FilledButton, l.apply));
        await waitPreparation(tester);
        const prepared = '第一段\n第二段 x²；代码 x^2';
        expect(workspace.text, prepared);
        await openCleanup();
        await tester.tap(find.widgetWithText(FilledButton, l.apply));
        await waitPreparation(tester);
        expect(workspace.text, prepared);
        final undoButton = find.widgetWithText(TextButton, l.undo);
        await tester.ensureVisible(undoButton);
        await tester.tap(undoButton);
        await tester.pumpAndSettle();
        expect(workspace.text, manual);
        await tester.tap(find.widgetWithText(TextButton, l.redo));
        await tester.pumpAndSettle();
        expect(workspace.text, prepared);
        await tester.enterText(input, '新内容');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, l.redo));
        await tester.pumpAndSettle();
        expect(workspace.text, '新内容');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'long text preparation can stop and retry without overwriting a changed source',
    (tester) async {
      final workspace = await openWorkbench(tester, size: const Size(375, 800));
      final l = labels(tester);
      final input = find.byKey(const ValueKey('text-editor'));
      final original = List.filled(
        12000,
        r'$\frac{1}{x^2}+\sqrt{3}$',
      ).join('\n');
      Future<void> start() async {
        await tester.tap(find.byKey(const ValueKey('editor-tools')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, l.prepareText));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, l.apply));
        await tester.pump();
      }

      await tester.enterText(input, original);
      await start();
      expect(
        find.byKey(const ValueKey('stop-text-preparation')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('stop-text-preparation')));
      await waitPreparation(tester);
      expect(workspace.text, original);
      await start();
      workspace.text = 'New source';
      workspace.emit();
      await waitPreparation(tester);
      expect(workspace.text, 'New source');
      await tester.enterText(input, r'**Retry** $x^2$');
      await start();
      await waitPreparation(tester);
      expect(workspace.text, 'Retry x²');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile app settings name language and theme actions', (
    tester,
  ) async {
    await openWorkbench(tester, size: const Size(375, 800));
    var l = labels(tester);
    await tester.tap(find.byKey(const ValueKey('app-preferences')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, l.language), findsOneWidget);
    expect(find.widgetWithText(ListTile, l.theme), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, l.language));
    await tester.pumpAndSettle();
    expect(
      Localizations.localeOf(
        tester.element(find.byKey(const ValueKey('text-editor'))),
      ).languageCode,
      'en',
    );
    l = labels(tester);
    await tester.tap(find.byKey(const ValueKey('app-preferences')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, l.theme));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('text-editor'))))
          .brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing table mode prepares the original and preserves code', (
    tester,
  ) async {
    final workspace = await openWorkbench(tester, size: const Size(1440, 1000));
    final l = labels(tester);
    const original = '代码 `x^2`\n| 变量 | 值 |\n| --- | --- |\n| a | \$x^2\$ |';
    final input = find.byKey(const ValueKey('text-editor'));
    await tester.enterText(input, original);
    await tester.pumpAndSettle();
    Future<void> openPrepare() async {
      final more = find.byKey(const ValueKey('editor-tools'));
      if (more.evaluate().isNotEmpty) {
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, l.prepareText));
      } else {
        await tester.tap(find.widgetWithText(TextButton, l.prepareText));
      }
      await tester.pumpAndSettle();
    }

    await openPrepare();
    await tester.tap(find.widgetWithText(FilledButton, l.apply));
    await waitPreparation(tester);
    expect(workspace.text, contains('⟦'));
    expect(workspace.text, startsWith('代码 x^2'));
    await openPrepare();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(DropdownButtonFormField<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.listMode).last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.apply));
    await waitPreparation(tester);
    expect(workspace.text, startsWith('代码 x^2'));
    expect(workspace.text, isNot(contains('⟦')));
    expect(workspace.text, contains('x²'));
    await tester.tap(find.widgetWithText(TextButton, l.undo));
    await tester.pumpAndSettle();
    expect(workspace.text, original);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile editing survives keyboard with bottom navigation hidden',
    (tester) async {
      final workspace = await openWorkbench(
        tester,
        size: const Size(320, 800),
        locale: const Locale('en'),
      );
      expect(find.byType(NavigationBar), findsOneWidget);
      final editor = find.byKey(const ValueKey('text-editor'));
      await tester.tap(editor);
      await tester.pumpAndSettle();
      final focus = tester.widget<TextField>(editor).focusNode!;
      final editable = find.descendant(
        of: editor,
        matching: find.byType(EditableText),
      );
      final editingState = tester.state<EditableTextState>(editable);
      expect(focus.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      // Exercise the real Scaffold boundary: body descendants see consumed
      // insets, so footer visibility must use the value captured above it.
      expect(MediaQuery.viewInsetsOf(tester.element(editor)).bottom, 0);
      expect(find.byKey(const ValueKey('generate-preview')), findsNothing);
      expect(find.byKey(const ValueKey('export-pdf')), findsNothing);
      expect(find.byKey(const ValueKey('export-zip')), findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(tester.state<EditableTextState>(editable), same(editingState));
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(editor, 'Keyboard input');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(workspace.text, 'Keyboard input');
      expect(focus.hasFocus, isTrue);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('generate-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-pdf')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-zip')), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      expect(tester.state<EditableTextState>(editable), same(editingState));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip(labels(tester).dismissKeyboard), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('landscape workbench remains usable with larger text', (
    tester,
  ) async {
    final workspace = await openWorkbench(
      tester,
      size: const Size(740, 360),
      locale: const Locale('en'),
      textScale: 1.3,
    );
    await tester.enterText(
      find.byKey(const ValueKey('text-editor')),
      'Landscape',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(workspace.text, 'Landscape');
    expect(find.byKey(const ValueKey('editor-tools')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final corruptImage in ['%%%', 'data:image/png;base64,SGVsbG8=']) {
    testWidgets('corrupt illustration stays editable: $corruptImage', (
      tester,
    ) async {
      final workspace = await openWorkbench(tester, size: const Size(375, 800));
      workspace.text = '![插图 1]';
      workspace.images = {'1': corruptImage};
      workspace.emit();
      await tester.pumpAndSettle();
      expect(find.text(labels(tester).imageUnavailable), findsOneWidget);
      expect(find.byKey(const ValueKey('text-editor')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('generation can be cancelled directly from mobile editor', (
    tester,
  ) async {
    final workspace = await openWorkbench(
      tester,
      size: const Size(375, 800),
      generating: true,
    );
    final cancel = find.byKey(const ValueKey('cancel-generation'));
    expect(cancel, findsOneWidget);
    expect(find.byKey(const ValueKey('text-editor')), findsOneWidget);
    final api = workspace.api as MobileTestApi;
    api.stoppingGate = Completer<void>();
    await tester.tap(cancel);
    await tester.pump();
    expect(workspace.busy, isTrue);
    expect(find.textContaining(labels(tester).stoppingTask), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel-generation')), findsNothing);
    api.stoppingGate!.complete();
    await tester.pumpAndSettle();
    expect((workspace.api as MobileTestApi).cancelled, 'mobile-task');
    expect(workspace.busy, isFalse);
    expect(tester.takeException(), isNull);
  });
}
