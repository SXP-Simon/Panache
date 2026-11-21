import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/desktop_bootstrap.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/theme/nouveau_ornament.dart';

void main() {
  testWidgets(
    'buttons use the workbench color transition and keep ink feedback',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: handwritingTheme(Brightness.light),
          home: Scaffold(
            body: Row(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Fill')),
                OutlinedButton(onPressed: () {}, child: const Text('Outline')),
                TextButton(onPressed: () {}, child: const Text('Text')),
                IconButton(onPressed: () {}, icon: const Icon(Icons.edit)),
              ],
            ),
          ),
        ),
      );
      for (final button in [
        find.text('Fill'),
        find.text('Outline'),
        find.text('Text'),
        find.byIcon(Icons.edit),
      ]) {
        final local = tester.widgetList<AnimatedTheme>(
          find.ancestor(of: button, matching: find.byType(AnimatedTheme)),
        );
        expect(local.first.duration, Duration.zero);
        expect(
          find.ancestor(of: button, matching: find.byType(InkWell)),
          findsWidgets,
        );
      }
    },
  );

  test('day and night workspaces use botanical surfaces and legible type', () {
    for (final brightness in Brightness.values) {
      final theme = handwritingTheme(brightness);
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, brightness);
      expect(
        theme.textTheme.bodyMedium!.fontFamily,
        'packages/handwriting_assets/LXGW WenKai',
      );
      expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      final title = theme.textTheme.titleLarge!;
      expect(title.fontFamily, 'Playfair Display');
      expect(
        title.fontFamilyFallback,
        contains(theme.textTheme.bodyMedium!.fontFamily),
      );
      final scheme = theme.colorScheme;
      for (final pair in [
        (scheme.onSurface, scheme.surface),
        (scheme.onSurfaceVariant, scheme.surface),
        (scheme.onPrimary, scheme.primary),
        (scheme.onSecondaryContainer, scheme.secondaryContainer),
      ]) {
        final lightness = [
          pair.$1.computeLuminance(),
          pair.$2.computeLuminance(),
        ]..sort();
        expect(
          (lightness.last + .05) / (lightness.first + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
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

  test('night accents follow the saved seed across reading surfaces', () {
    final defaults = handwritingTheme(Brightness.dark).colorScheme;
    expect(defaults.primary, NouveauColors.moonMint);
    expect(defaults.secondary, NouveauColors.moonIris);
    final theme = handwritingTheme(
      Brightness.dark,
      seedColor: const Color(0xFF3C96CA),
    );
    final custom = theme.colorScheme;
    expect(custom.primary, isNot(defaults.primary));
    expect(custom.primary.b, greaterThan(custom.primary.r));
    expect(custom.surface, isNot(defaults.surface));
    expect(custom.surfaceContainerHigh, isNot(defaults.surfaceContainerHigh));
    expect(custom.outlineVariant, isNot(defaults.outlineVariant));
    expect(custom.secondary, defaults.secondary);
    final style = theme.filledButtonTheme.style!;
    Color? overlay(Set<WidgetState> states) =>
        style.overlayColor!.resolve(states);
    expect(style.backgroundColor!.resolve({}), isNull);
    expect(
      overlay({WidgetState.pressed}),
      isNot(overlay({WidgetState.hovered})),
    );
    expect(
      overlay({WidgetState.disabled, WidgetState.hovered}),
      Colors.transparent,
    );
    expect(
      style.backgroundColor!.resolve({WidgetState.disabled}),
      custom.surfaceContainerHigh,
    );
    expect(style.side!.resolve({WidgetState.focused})!.width, greaterThan(1));
    expect(
      style.side!.resolve({WidgetState.focused, WidgetState.disabled}),
      BorderSide.none,
    );
  });

  test('neutral reading surfaces stay lifted and legible for vivid and preset colors', () {
    for (final brightness in Brightness.values) {
      final accents = <Color>{};
      for (final (primary, accent) in [
        (defaultThemeColor, defaultSecondaryThemeColor),
        (const Color(0xFF27665D), const Color(0xFFA28247)),
        (const Color(0xFF924E56), const Color(0xFF597C70)),
        (const Color(0xFF3C96CA), const Color(0xFF7955A3)),
        (const Color(0xFFFF00FF), const Color(0xFF00FF00)),
      ]) {
        final theme = handwritingTheme(
          brightness,
          seedColor: primary,
          secondaryColor: accent,
        );
        final scheme = theme.colorScheme;
        final masthead = theme.appBarTheme.backgroundColor!;
        final field = theme.inputDecorationTheme.fillColor!;
        final panel = theme.cardTheme.color!;
        expect(accents.add(scheme.primary), isTrue);
        for (final background in [scheme.surface, panel, masthead, field]) {
          final channels = [background.r, background.g, background.b]..sort();
          expect(channels.last - channels.first, lessThan(.065));
          expect(
            background.computeLuminance(),
            brightness == Brightness.dark
                ? inInclusiveRange(.020, .080)
                : greaterThan(.80),
          );
        }
        expect(
          panel.computeLuminance(),
          greaterThan(scheme.surface.computeLuminance()),
        );
        if (brightness == Brightness.dark) {
          expect(
            field.computeLuminance(),
            greaterThan(scheme.surface.computeLuminance()),
          );
        }
        for (final (ink, fill) in [
          (scheme.onSurface, scheme.surface),
          (scheme.onSurface, field),
          (scheme.onSurfaceVariant, panel),
          (theme.appBarTheme.foregroundColor!, masthead),
          (scheme.onSecondaryContainer, scheme.secondaryContainer),
          (scheme.onPrimary, scheme.primary),
        ]) {
          final values = [ink.computeLuminance(), fill.computeLuminance()]
            ..sort();
          expect(
            (values.last + .05) / (values.first + .05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
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
