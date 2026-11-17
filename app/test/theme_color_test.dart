import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/services/appearance_preferences.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/widgets/theme_color_editor.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'theme swatches are selectable and validate hex in a narrow dialog',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      Color? saved;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ThemeColorEditor(
                color: defaultThemeColor,
                secondaryColor: defaultSecondaryThemeColor,
                onChanged: (_) async => true,
                onSecondaryChanged: (value) async {
                  saved = value;
                  return false;
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('pick-secondary-theme-color')),
      );
      await tester.pumpAndSettle();
      final area = find.byKey(const ValueKey('secondary-theme-color-area'));
      expect(area, findsOneWidget);
      await tester.tapAt(tester.getCenter(area));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('secondary-theme-color-hex'));
      final apply = find.byKey(const ValueKey('secondary-theme-color-apply'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      await tester.ensureVisible(input);
      await tester.enterText(input, '#NOPE');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(
        find.text('Enter six hexadecimal digits, e.g. #3C96CA'),
        findsOneWidget,
      );
      expect(saved, isNull);
      await tester.ensureVisible(input);
      await tester.enterText(input, '#168478');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(saved, const Color(0xFF168478));
      expect(
        find.text(
          'Color applied for this session. Unable to save it on this device.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'primary and secondary controls update and restore independently without changing paper',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = Workspace()..fonts = ['test.ttf'];
      workspace.settings.font = 'test.ttf';
      final paper = workspace.settings.toJson();
      addTearDown(workspace.dispose);
      final appWidget = HandwritingApp(
        locale: const Locale('en'),
        workspace: workspace,
      );
      await tester.pumpWidget(appWidget);
      await tester.pumpAndSettle();

      MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
      final initial = app().theme!.colorScheme;
      await tester.tap(find.byKey(const ValueKey('app-preferences')));
      await tester.pumpAndSettle();

      Future<void> choose(String role, String hex) async {
        final row = find.byKey(ValueKey('pick-$role-theme-color'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        final input = find.byKey(ValueKey('$role-theme-color-hex'));
        await tester.ensureVisible(input);
        await tester.enterText(input, hex);
        final apply = find.byKey(ValueKey('$role-theme-color-apply'));
        await tester.ensureVisible(apply);
        await tester.tap(apply);
        await tester.pumpAndSettle();
      }

      await choose('primary', '#7955A3');
      final afterPrimary = app().theme!.colorScheme;
      expect(afterPrimary.primary, isNot(initial.primary));
      expect(afterPrimary.secondaryContainer, initial.secondaryContainer);
      await choose('secondary', '#168478');
      final light = app().theme!.colorScheme;
      final dark = app().darkTheme!.colorScheme;
      expect(light.primary, afterPrimary.primary);
      expect(light.secondaryContainer, isNot(afterPrimary.secondaryContainer));
      expect(
        dark,
        handwritingTheme(
          Brightness.dark,
          seedColor: const Color(0xFF7955A3),
          secondaryColor: const Color(0xFF168478),
        ).colorScheme,
      );
      expect(workspace.settings.toJson(), paper);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt(AppearancePreferences.colorKey), 0xFF7955A3);
      expect(
        preferences.getInt(AppearancePreferences.secondaryColorKey),
        0xFF168478,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(appWidget);
      await tester.pumpAndSettle();
      expect(app().theme!.colorScheme, light);
      expect(app().darkTheme!.colorScheme, dark);
    },
  );
}
