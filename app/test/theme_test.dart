import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/desktop_bootstrap.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';

void main() {
  test('shared UI themes use WenKai, neutral surfaces and Material 3', () {
    for (final brightness in Brightness.values) {
      final theme = handwritingTheme(brightness);
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, brightness);
      expect(
        theme.textTheme.bodyMedium!.fontFamily,
        'packages/handwriting_assets/LXGW WenKai',
      );
      expect(
        theme.scaffoldBackgroundColor,
        brightness == Brightness.light ? Colors.white : const Color(0x6B000000),
      );
      expect(theme.colorScheme.surfaceTint, Colors.transparent);
      expect(
        theme.navigationRailTheme.selectedLabelTextStyle!.fontFamily,
        theme.textTheme.labelMedium!.fontFamily,
      );
      expect(
        theme.navigationRailTheme.unselectedLabelTextStyle!.fontFamily,
        theme.textTheme.labelMedium!.fontFamily,
      );
    }
  });

  testWidgets('startup and recovery app use the shared system dark theme', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      DesktopBootstrap(builder: (_) => const SizedBox.shrink()),
    );
    final application = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(application.themeMode, ThemeMode.system);
    expect(
      application.darkTheme!.colorScheme,
      handwritingTheme(Brightness.dark).colorScheme,
    );
    final context = tester.element(find.byType(Scaffold));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(
      Theme.of(context).textTheme.bodyMedium!.fontFamily,
      'packages/handwriting_assets/LXGW WenKai',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
