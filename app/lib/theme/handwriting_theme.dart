import 'package:flutter/material.dart';

import 'nouveau_ornament.dart';

const defaultThemeColor = NouveauColors.forest;
const defaultSecondaryThemeColor = NouveauColors.wisteria;

/// An opaque base lets translucent dark surfaces composite consistently.
Widget handwritingBackdrop(BuildContext context, Widget? child) =>
    ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: child!);

/// Shared appearance for the workbench, startup and recovery screens.
ThemeData handwritingTheme(
  Brightness brightness, {
  Color seedColor = defaultThemeColor,
  Color secondaryColor = defaultSecondaryThemeColor,
}) {
  final dark = brightness == Brightness.dark;
  final surface = dark ? NouveauColors.night : NouveauColors.ivory;
  final raised = dark ? const Color(0xFF283329) : NouveauColors.softIvory;
  final foreground = dark ? NouveauColors.ivory : NouveauColors.forest;
  final muted = dark ? const Color(0xFFBFC9B5) : const Color(0xFF526047);
  final outline = dark ? const Color(0xFF9B997C) : const Color(0xFF797456);
  final border = Color.alphaBlend(
    NouveauColors.gold.withValues(alpha: dark ? .50 : .40),
    raised,
  );
  final primary = _readableAccent(
    seedColor,
    surface,
    foreground,
    dark ? .55 : 0,
    4.5,
  );
  final primaryContainer = Color.alphaBlend(
    seedColor.withValues(alpha: dark ? .32 : .20),
    raised,
  );
  final secondaryContainer = Color.alphaBlend(
    secondaryColor.withValues(alpha: dark ? .21 : .13),
    raised,
  );
  final secondary = _readableAccent(
    secondaryColor,
    secondaryContainer,
    foreground,
    dark ? .48 : .22,
    4.5,
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: brightness,
      ).copyWith(
        primary: primary,
        onPrimary: !dark && seedColor == defaultThemeColor
            ? NouveauColors.ivory
            : _onSolidColor(primary),
        primaryContainer: primaryContainer,
        onPrimaryContainer: foreground,
        secondary: secondary,
        onSecondary: _onSolidColor(secondary),
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: secondary,
        tertiary: dark ? NouveauColors.gold : const Color(0xFF78601B),
        surface: surface,
        onSurface: foreground,
        onSurfaceVariant: muted,
        surfaceDim: dark ? const Color(0xFF131B15) : const Color(0xFFE9E3D1),
        surfaceBright: dark ? const Color(0xFF343F32) : NouveauColors.softIvory,
        surfaceContainerLowest: dark
            ? const Color(0xFF121B14)
            : NouveauColors.softIvory,
        surfaceContainerLow: dark
            ? const Color(0xFF202B22)
            : const Color(0xFFFBF8EE),
        surfaceContainer: raised,
        surfaceContainerHigh: dark
            ? const Color(0xFF303D30)
            : const Color(0xFFEEE9D8),
        surfaceContainerHighest: dark
            ? const Color(0xFF3A4738)
            : const Color(0xFFE5DFCA),
        outline: outline,
        outlineVariant: border,
        surfaceTint: Colors.transparent,
      );

  const controlShape = StadiumBorder();
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(32),
    side: BorderSide(color: border),
  );
  OutlineInputBorder fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        borderSide: BorderSide(color: color, width: width),
      );

  final theme = ThemeData(
    useMaterial3: true,
    fontFamily: 'packages/handwriting_assets/LXGW WenKai',
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
    appBarTheme: AppBarThemeData(
      backgroundColor: surface,
      foregroundColor: foreground,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(color: border),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: border),
      selectedColor: primaryContainer,
      checkmarkColor: foreground,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: fieldBorder(border),
      enabledBorder: fieldBorder(border),
      focusedBorder: fieldBorder(primary, width: 2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    cardTheme: CardThemeData(
      elevation: 2,
      shadowColor: NouveauColors.forest.withValues(alpha: .22),
      margin: EdgeInsets.zero,
      color: raised,
      shape: cardShape,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        animationDuration: const Duration(milliseconds: 500),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) &&
                  !states.contains(WidgetState.disabled)
              ? NouveauColors.gold
              : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) &&
                  !states.contains(WidgetState.disabled)
              ? NouveauColors.night
              : null,
        ),
        shape: const WidgetStatePropertyAll(controlShape),
        side: const WidgetStatePropertyAll(
          BorderSide(color: NouveauColors.gold),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: controlShape,
        side: BorderSide(color: border),
        animationDuration: const Duration(milliseconds: 500),
        foregroundColor: foreground,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: controlShape,
        foregroundColor: foreground,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(controlShape),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) &&
                  !states.contains(WidgetState.disabled)
              ? primaryContainer
              : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) &&
                  !states.contains(WidgetState.disabled)
              ? foreground
              : null,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(backgroundColor: raised, shape: cardShape),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      modalBackgroundColor: raised,
      dragHandleColor: outline,
    ),
  );
  final railLabel = theme.textTheme.labelMedium!;
  TextStyle? heading(TextStyle? style) => style?.copyWith(
    fontFamily: 'Playfair Display',
    fontFamilyFallback: const [
      'packages/handwriting_assets/LXGW WenKai',
      'Georgia',
      'serif',
    ],
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      displayLarge: heading(theme.textTheme.displayLarge)
          ?.copyWith(fontSize: 60, height: 1.1, fontWeight: FontWeight.w700),
      displayMedium: heading(theme.textTheme.displayMedium),
      displaySmall: heading(theme.textTheme.displaySmall),
      headlineSmall: heading(theme.textTheme.headlineSmall),
      headlineMedium: heading(theme.textTheme.headlineMedium),
      titleSmall: heading(theme.textTheme.titleSmall),
      headlineLarge: heading(theme.textTheme.headlineLarge)
          ?.copyWith(fontSize: 36, height: 1.25, fontWeight: FontWeight.w700),
      titleLarge: heading(theme.textTheme.titleLarge)
          ?.copyWith(fontSize: 26, height: 1.35, fontWeight: FontWeight.w700),
      titleMedium: heading(theme.textTheme.titleMedium)
          ?.copyWith(fontSize: 20, height: 1.25, fontWeight: FontWeight.w700),
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(height: 1.8),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: primaryContainer,
      selectedIconTheme: IconThemeData(color: primary),
      unselectedIconTheme: IconThemeData(color: muted),
      selectedLabelTextStyle: railLabel.copyWith(
        color: foreground,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: railLabel.copyWith(color: muted),
    ),
  );
}

Color _onSolidColor(Color background) =>
    background.computeLuminance() > .179 ? Colors.black : Colors.white;

Color _readableAccent(
  Color seed,
  Color background,
  Color foreground,
  double blend,
  double minimumContrast,
) {
  final backgroundLightness = background.computeLuminance();
  final accent = Color.lerp(seed, foreground, blend)!;
  final accentLightness = accent.computeLuminance();
  final contrast = accentLightness > backgroundLightness
      ? (accentLightness + .05) / (backgroundLightness + .05)
      : (backgroundLightness + .05) / (accentLightness + .05);
  return contrast >= minimumContrast
      ? accent
      : Color.lerp(seed, foreground, .8)!;
}
