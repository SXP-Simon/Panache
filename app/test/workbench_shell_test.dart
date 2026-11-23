import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/widgets/workbench_shell.dart';

void main() {
  Widget shell({
    VoidCallback? onLocale,
    ValueChanged<int>? onDestination,
    Widget Function(bool, double)? workspaceBuilder,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: WorkbenchShell(
      destination: 0,
      onDestinationSelected: onDestination ?? (_) {},
      connected: true,
      managedBackend: false,
      locked: false,
      onConnection: () {},
      onToggleLocale: onLocale ?? () {},
      onToggleTheme: () {},
      workspaceBuilder: workspaceBuilder ?? (_, _) => const SizedBox.expand(),
      informationBuilder: () => const SizedBox.expand(),
    ),
  );

  for (final width in [320.0, 375.0, 1280.0]) {
    testWidgets('repository link stays accessible at $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? openedUrl;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          openedUrl =
              (call.arguments as Map<Object?, Object?>)['url'] as String;
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(shell());
      if (width < 900) {
        expect(find.byType(AppBar), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-preferences')));
        await tester.pumpAndSettle();
      }
      final link = find.byKey(const ValueKey('project-source-link'));
      if (width < 900) {
        final scrollable = find.descendant(
          of: find.byKey(const ValueKey('app-settings-list')),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(link, 160, scrollable: scrollable);
        await tester.pumpAndSettle();
      }
      expect(link, findsOneWidget);
      expect(find.byKey(const ValueKey('panache-brand-mark')), findsNothing);
      expect(find.text('SXP-Simon/Panache'), findsOneWidget);

      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(openedUrl, 'https://github.com/SXP-Simon/Panache');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mobile preferences expose named actions and return callbacks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var localeCalls = 0;
    await tester.pumpWidget(shell(onLocale: () => localeCalls++));
    await tester.tap(find.byKey(const ValueKey('app-preferences')));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(WorkbenchShell));
    final l = AppLocalizations.of(context)!;
    final language = find.widgetWithText(ListTile, l.language);
    expect(language, findsOneWidget);
    expect(find.widgetWithText(ListTile, l.theme), findsOneWidget);
    expect(find.widgetWithText(ListTile, l.connection), findsOneWidget);
    await tester.tap(language);
    await tester.pumpAndSettle();
    expect(localeCalls, 1);
    expect(find.byType(BottomSheet), findsNothing);
  });

  for (final width in [899.0, 900.0, 1099.0, 1100.0]) {
    testWidgets('keyboard and navigation actions at width ${width.toInt()}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      tester.view.padding = const FakeViewPadding(left: 25, right: 25);
      addTearDown(tester.view.resetPadding);
      bool? bodyWide;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        shell(
          workspaceBuilder: (wide, _) {
            bodyWide = wide;
            return TextField(focusNode: focus);
          },
        ),
      );
      final labels = AppLocalizations.of(
        tester.element(find.byType(WorkbenchShell)),
      )!;
      expect(bodyWide, width - 50 >= 900);
      expect(
        find.byKey(const ValueKey('open-guide')),
        width >= 900 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byTooltip(labels.language),
        width >= 1100 ? findsOneWidget : findsNothing,
      );
      expect(find.byIcon(Icons.keyboard_hide_outlined), findsNothing);
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      if (width >= 1100) {
        expect(find.byIcon(Icons.keyboard_hide_outlined), findsNothing);
      } else {
        final button = find.widgetWithIcon(
          width < 900 ? FloatingActionButton : TextButton,
          Icons.keyboard_hide_outlined,
        );
        expect(button, findsOneWidget);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isFalse);
      }
    });
  }
}
