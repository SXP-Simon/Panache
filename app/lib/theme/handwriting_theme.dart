import 'package:flutter/material.dart';

const defaultThemeColor = Color(0xFF3C96CA);
const defaultSecondaryThemeColor = Color(0xFF2F86BD);
const _darkBase = Color(0xFF222327);

/// An opaque base lets translucent dark surfaces composite consistently.
Widget handwritingBackdrop(BuildContext context, Widget? child) => ColoredBox(
  color: Theme.of(context).brightness == Brightness.dark
      ? _darkBase
      : Colors.white,
  child: child!,
);

/// Shared appearance for the workbench, startup and recovery screens.
ThemeData handwritingTheme(
  Brightness brightness, {
  Color seedColor = defaultThemeColor,
  Color secondaryColor = defaultSecondaryThemeColor,
}) {
  final dark = brightness == Brightness.dark;
  final surface = dark ? const Color(0xFF1B1C1F) : Colors.white;
  final raised = dark ? const Color(0xFF282A2E) : const Color(0xFFF7F8FA);
  final foreground = dark ? const Color(0xFFF2F3F6) : const Color(0xFF20232A);
  final muted = dark ? const Color(0xFFB5BAC3) : const Color(0xFF5C626D);
  final outline = dark ? const Color(0xFF747984) : const Color(0xFF707785);
  final border = dark ? const Color(0xFF373A41) : const Color(0xFFDEE1E7);
  final primary = _readableAccent(
    seedColor,
    surface,
    foreground,
    dark ? .36 : .28,
    3,
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
    dark ? .48 : .55,
    4.5,
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: defaultThemeColor,
        brightness: brightness,
      ).copyWith(
        primary: primary,
        onPrimary: _onSolidColor(primary),
        primaryContainer: primaryContainer,
        onPrimaryContainer: foreground,
        secondary: secondary,
        onSecondary: _onSolidColor(secondary),
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: secondary,
        surface: surface,
        onSurface: foreground,
        onSurfaceVariant: muted,
        surfaceDim: dark ? const Color(0xFF151619) : const Color(0xFFF0F1F4),
        surfaceBright: dark ? const Color(0xFF303238) : Colors.white,
        surfaceContainerLowest: dark ? const Color(0xFF141518) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF232529)
            : const Color(0xFFFAFAFB),
        surfaceContainer: raised,
        surfaceContainerHigh: dark
            ? const Color(0xFF2E3035)
            : const Color(0xFFF0F2F5),
        surfaceContainerHighest: dark
            ? const Color(0xFF34363C)
            : const Color(0xFFEAEDF2),
        outline: outline,
        outlineVariant: border,
        surfaceTint: Colors.transparent,
      );

  const controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  );
  OutlineInputBorder fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: color, width: width),
      );

  final theme = ThemeData(
    useMaterial3: true,
    fontFamily: 'packages/handwriting_assets/LXGW WenKai',
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0x6B000000) : Colors.white,
    appBarTheme: AppBarThemeData(
      backgroundColor: surface,
      foregroundColor: foreground,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: border)),
    ),
    dividerTheme: DividerThemeData(color: border),
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
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? const Color(0x26000000) : Colors.white,
      shape: controlShape.copyWith(side: BorderSide(color: border)),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(controlShape)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: controlShape,
        side: BorderSide(color: border),
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
    dialogTheme: DialogThemeData(
      backgroundColor: raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      modalBackgroundColor: raised,
      dragHandleColor: outline,
    ),
  );
  final railLabel = theme.textTheme.labelMedium!;
  return theme.copyWith(
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
