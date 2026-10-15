import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/screens/dialogs/connection_dialog.dart';
import 'package:handwriting_app/screens/dialogs/text_tools_dialogs.dart';
import 'package:handwriting_app/screens/dialogs/text_preview_dialog.dart';

Future<void> host(
  WidgetTester tester,
  Future<void> Function(BuildContext) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => open(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connection validates locally and returns the accepted origin', (
    tester,
  ) async {
    String? result;
    await host(tester, (context) async {
      result = await showConnectionDialog(
        context,
        initialBase: 'https://example.org/path',
      );
    });
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
      isNotNull,
    );
    await tester.enterText(find.byType(TextField), 'https://example.org');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(result, 'https://example.org');
    expect(tester.takeException(), isNull);
  });
  testWidgets('markdown dialog returns mode without modifying source', (
    tester,
  ) async {
    String? result;
    await host(tester, (context) async {
      result = await showMarkdownDialog(context, initialMode: 'aligned');
    });
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(result, 'aligned');
    expect(tester.takeException(), isNull);
  });
  testWidgets('letter dialog returns inputs on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    LetterInputs? result;
    await host(tester, (context) async {
      result = await showLetterDialog(
        context,
        initial: (body: 'Hello', signature: 'Simon', date: '2026'),
      );
    });
    await tester.enterText(find.byType(TextField).first, 'New body');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(result, (body: 'New body', signature: 'Simon', date: '2026'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('text preview protects literal math in code and links', (
    tester,
  ) async {
    await host(
      tester,
      (context) => showTextPreviewDialog(
        context,
        text: r'`$x^2$` https://example.org/$x^2$ and $x_1$',
        onOpenLink: (_) {},
      ),
    );
    expect(find.byType(Math), findsOneWidget);
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
