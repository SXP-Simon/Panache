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
  final raised = dark ? const Color(0xFF202634) : NouveauColors.softIvory;
  final foreground = dark ? const Color(0xFFEDF1FC) : NouveauColors.forest;
  final muted = dark ? const Color(0xFFBBC3D5) : const Color(0xFF526047);
  final outline = dark ? const Color(0xFF8793AB) : const Color(0xFF797456);
  final base = ColorScheme.fromSeed(
    seedColor: dark && seedColor == defaultThemeColor
        ? NouveauColors.moonMint
        : seedColor,
    brightness: brightness,
  );
  final primary = dark
      ? (seedColor == defaultThemeColor ? NouveauColors.moonMint : base.primary)
      : _readableAccent(seedColor, surface, foreground, 0, 4.5);
  final primaryContainer = Color.alphaBlend(
    (dark ? primary : seedColor).withValues(alpha: dark ? .16 : .20),
    raised,
  );
  final secondaryContainer = Color.alphaBlend(
    (dark && secondaryColor == defaultSecondaryThemeColor
            ? NouveauColors.moonIris
            : secondaryColor)
        .withValues(alpha: dark ? .16 : .13),
    raised,
  );
  final secondary = dark && secondaryColor == defaultSecondaryThemeColor
      ? NouveauColors.moonIris
      : _readableAccent(
          secondaryColor,
          secondaryContainer,
          foreground,
          dark ? .55 : .22,
          4.5,
        );
  final border = dark
      ? Color.lerp(const Color(0xFF394055), primary, .09)!
      : Color.alphaBlend(NouveauColors.gold.withValues(alpha: .40), raised);
  final scheme = base.copyWith(
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
    tertiary: dark
        ? Color.lerp(primary, secondary, .65)!
        : const Color(0xFF78601B),
    surface: surface,
    onSurface: foreground,
    onSurfaceVariant: muted,
    surfaceDim: dark ? const Color(0xFF0D101A) : const Color(0xFFE9E3D1),
    surfaceBright: dark ? const Color(0xFF394155) : NouveauColors.softIvory,
    surfaceContainerLowest: dark
        ? const Color(0xFF0C1019)
        : NouveauColors.softIvory,
    surfaceContainerLow: dark
        ? const Color(0xFF181D29)
        : const Color(0xFFFBF8EE),
    surfaceContainer: raised,
    surfaceContainerHigh: dark
        ? const Color(0xFF293043)
        : const Color(0xFFEEE9D8),
    surfaceContainerHighest: dark
        ? const Color(0xFF343C50)
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
      shadowColor: dark
          ? Colors.black54
          : NouveauColors.forest.withValues(alpha: .22),
      margin: EdgeInsets.zero,
      color: raised,
      shape: cardShape,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: dark
          ? _nightFilledButton(scheme)
          : ButtonStyle(
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
                    ? const Color(0xFF172019)
                    : null,
              ),
              shape: const WidgetStatePropertyAll(controlShape),
              side: const WidgetStatePropertyAll(
                BorderSide(color: NouveauColors.gold),
              ),
            ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            shape: controlShape,
            side: BorderSide(color: border),
            animationDuration: const Duration(milliseconds: 500),
            foregroundColor: foreground,
          ).copyWith(
            side: dark
                ? WidgetStateProperty.resolveWith(
                    (states) => BorderSide(
                      color: states.contains(WidgetState.disabled)
                          ? border
                          : states.contains(WidgetState.focused)
                          ? secondary
                          : states.contains(WidgetState.hovered) ||
                                states.contains(WidgetState.pressed)
                          ? primary
                          : outline,
                      width: states.contains(WidgetState.focused) ? 2 : 1,
                    ),
                  )
                : null,
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

ButtonStyle _nightFilledButton(ColorScheme colors) {
  return ButtonStyle(
    shape: const WidgetStatePropertyAll(StadiumBorder()),
    animationDuration: const Duration(milliseconds: 500),
    // Keep the native base colors of filled and tonal variants.
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.pressed)) {
        return colors.surface.withValues(alpha: .18);
      }
      if (states.contains(WidgetState.hovered)) {
        return Colors.white.withValues(alpha: .15);
      }
      return null;
    }),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.surfaceContainerHigh
          : null,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.onSurfaceVariant.withValues(alpha: .62)
          : null,
    ),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return BorderSide.none;
      if (states.contains(WidgetState.focused)) {
        return BorderSide(color: colors.onSurface, width: 2);
      }
      return BorderSide.none;
    }),
  );
}
