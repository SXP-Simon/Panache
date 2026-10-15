import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/widgets/workbench_shell.dart';

void main() {
  Widget shell({VoidCallback? onLocale, ValueChanged<int>? onDestination}) =>
      MaterialApp(
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
          workspaceBuilder: (_, _) => const SizedBox.expand(),
          informationBuilder: () => const SizedBox.expand(),
        ),
      );

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

  testWidgets('mobile keyboard hides bottom navigation and offers dismissal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(shell());
    expect(find.byType(NavigationBar), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byIcon(Icons.keyboard_hide_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
