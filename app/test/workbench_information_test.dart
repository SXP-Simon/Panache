import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/widgets/workbench_information.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('About opens and closes the bundled tip code in $locale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: WorkbenchInformation()),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(WorkbenchInformation)),
      )!;
      final support = find.text(l.supportAuthor);
      await tester.scrollUntilVisible(support, 160);
      await tester.pumpAndSettle();
      await tester.tap(support);
      await tester.pumpAndSettle();
      expect(find.text(l.wechatTipHint), findsOneWidget);
      final code = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Image),
      );
      final image = tester.widget<Image>(code);
      expect(image.semanticLabel, l.wechatTipCode);
      final bundle = DefaultAssetBundle.of(tester.element(code));
      final asset = image.image as AssetImage;
      expect(
        (await bundle.load(asset.assetName)).lengthInBytes,
        greaterThan(0),
      );
      await tester.tap(find.widgetWithText(TextButton, l.close));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
