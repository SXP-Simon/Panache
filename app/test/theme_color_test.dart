import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/widgets/theme_color_editor.dart';
import 'package:handwriting_app/widgets/workbench_shell.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'settings sheet can apply and reset colors at 320px with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WorkbenchShell(
            destination: 0,
            onDestinationSelected: (_) {},
            connected: true,
            managedBackend: true,
            locked: false,
            onConnection: () {},
            onToggleLocale: () {},
            onToggleTheme: () {},
            workspaceBuilder: (_, _) => const SizedBox(),
            informationBuilder: () => const SizedBox(),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('app-preferences')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('theme-color-hex'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '#2962A3');
      await tester.ensureVisible(
        find.byKey(const ValueKey('apply-theme-color')),
      );
      await tester.tap(find.byKey(const ValueKey('apply-theme-color')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Restore green'));
      await tester.tap(find.text('Restore green'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'open editor shows persistence failure and stays usable with narrow keyboard layout',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ThemeColorEditor(
                color: defaultThemeColor,
                onChanged: (_) async => false,
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('theme-color-hex')),
        '#2962A3',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('apply-theme-color')),
      );
      await tester.tap(find.byKey(const ValueKey('apply-theme-color')));
      await tester.pumpAndSettle();
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
    'custom interface seed updates light and dark themes, survives restart, leaves paper unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = Workspace()..fonts = ['test.ttf'];
      workspace.settings.font = 'test.ttf';
      final paper = workspace.settings.toJson();
      addTearDown(workspace.dispose);
      await tester.pumpWidget(
        HandwritingApp(locale: const Locale('en'), workspace: workspace),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('app-preferences')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('theme-color-hex'));
      await tester.ensureVisible(input);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.ensureVisible(input);
      await tester.enterText(input, '#NOPE');
      await tester.ensureVisible(
        find.byKey(const ValueKey('apply-theme-color')),
      );
      await tester.tap(find.byKey(const ValueKey('apply-theme-color')));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter six hexadecimal digits, e.g. #62833A'),
        findsOneWidget,
      );
      await tester.enterText(input, '#7955A3');
      await tester.tap(find.byKey(const ValueKey('apply-theme-color')));
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(
        app.theme!.colorScheme,
        handwritingTheme(
          Brightness.light,
          seedColor: const Color(0xFF7955A3),
        ).colorScheme,
      );
      expect(
        app.darkTheme!.colorScheme,
        handwritingTheme(
          Brightness.dark,
          seedColor: const Color(0xFF7955A3),
        ).colorScheme,
      );
      expect(workspace.settings.toJson(), paper);
      expect(
        (await SharedPreferences.getInstance()).getInt('panache.themeColor'),
        0xFF7955A3,
      );
      tester.view.resetViewInsets();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        HandwritingApp(locale: const Locale('en'), workspace: workspace),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!.colorScheme,
        app.theme!.colorScheme,
      );
      await tester.tap(find.byKey(const ValueKey('app-preferences')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Restore green'));
      await tester.tap(find.text('Restore green'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getInt('panache.themeColor'),
        defaultThemeColor.toARGB32(),
      );
    },
  );
}
