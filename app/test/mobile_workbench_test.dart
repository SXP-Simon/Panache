import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';

class MobileTestApi extends HandwritingApi {
  MobileTestApi() : super('local://test-engine');
  String? cancelled;
  @override
  bool get supportsCancel => true;
  @override
  Future<void> cancelTask(String id) async => cancelled = id;
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
      ..busy = generating
      ..taskId = generating ? 'mobile-task' : ''
      ..phase = generating ? 'pending' : '';
    workspace.settings.font = 'test.ttf';
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
      expect(find.text(labels(tester).dismissKeyboard), findsOneWidget);
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
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect((workspace.api as MobileTestApi).cancelled, 'mobile-task');
    expect(workspace.busy, isFalse);
    expect(tester.takeException(), isNull);
  });
}
