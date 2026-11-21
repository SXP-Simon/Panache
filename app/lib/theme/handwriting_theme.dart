import 'package:flutter/material.dart';

import 'nouveau_ornament.dart';

const defaultThemeColor = NouveauColors.wisteria;
const defaultSecondaryThemeColor = NouveauColors.forest;

/// Black ink layers over a single opaque, neutral workbench background.
abstract final class NightSurfaces {
  static const panel = Color(0x40000000);
  static const navigation = Color(0x52000000);
  static const writing = Color(0x35000000);
  static const preview = Color(0x20000000);

  static LinearGradient backdrop(Color base) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.lerp(base, const Color(0xffa7a8ad), .22)!,
      base,
      Color.lerp(base, const Color(0xff202124), .48)!,
    ],
  );
}

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
  final iris =
      seedColor == defaultThemeColor &&
      secondaryColor == defaultSecondaryThemeColor;
  final hue = HSLColor.fromColor(
    seedColor == defaultThemeColor ? secondaryColor : seedColor,
  );
  // Large surfaces share a neutral ramp. Hue adds only a trace of warmth or
  // coolness; saturated user-picked colors stay on small interactive elements.
  final surfaceHue = iris ? (dark ? 226.0 : 38.0) : hue.hue;
  final saturation = iris
      ? (dark ? .036 : .13)
      : hue.saturation.clamp(0.0, dark ? .035 : .085);
  Color surfaceTone(double daylight, double moonlight) => HSLColor.fromAHSL(
    1,
    surfaceHue,
    saturation,
    dark ? moonlight : daylight,
  ).toColor();
  final surface = surfaceTone(.943, .285);
  final raised = surfaceTone(.982, .232);
  final foreground = dark ? NouveauColors.ivory : surfaceTone(.17, .943);
  final muted = surfaceTone(.355, .788);
  final outline = surfaceTone(.45, .66);
  final base = ColorScheme.fromSeed(
    seedColor: dark && seedColor == defaultThemeColor
        ? NouveauColors.moonIris
        : seedColor,
    brightness: brightness,
  );
  final primary = dark
      ? (seedColor == defaultThemeColor ? NouveauColors.moonIris : base.primary)
      : seedColor == defaultThemeColor
      ? _contrastingInk(seedColor, NouveauColors.ivory, false)
      : _readableAccent(seedColor, surface, foreground, 0, 4.5);
  final primaryContainer = Color.alphaBlend(
    (dark ? primary : seedColor).withValues(alpha: dark ? .16 : .20),
    raised,
  );
  final secondaryContainer = Color.alphaBlend(
    (dark && secondaryColor == defaultSecondaryThemeColor
            ? NouveauColors.nightSage
            : secondaryColor)
        .withValues(alpha: dark ? .16 : .13),
    dark ? const Color(0xFF383B41) : const Color(0xFFFAF9F7),
  );
  final secondary = dark && secondaryColor == defaultSecondaryThemeColor
      ? NouveauColors.nightSage
      : _contrastingInk(secondaryColor, secondaryContainer, dark);
  final trim = iris ? NouveauColors.gold : hue.withLightness(.60).toColor();
  final border = Color.lerp(
    surfaceTone(.81, .325),
    dark ? primary : trim,
    dark ? .08 : .15,
  )!;
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
        ? const Color(0xFFB8A982)
        : iris
        ? const Color(0xFF78601B)
        : hue.withLightness(.34).toColor(),
    surface: surface,
    onSurface: foreground,
    onSurfaceVariant: muted,
    surfaceDim: surfaceTone(.907, .166),
    surfaceBright: surfaceTone(.995, .315),
    surfaceContainerLowest: surfaceTone(.963, .198),
    surfaceContainerLow: surfaceTone(.971, .212),
    surfaceContainer: raised,
    surfaceContainerHigh: surfaceTone(.924, .258),
    surfaceContainerHighest: surfaceTone(.899, .28),
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
      backgroundColor: dark
          ? Color.alphaBlend(NightSurfaces.navigation, surface)
          : surfaceTone(.966, .222),
      foregroundColor: foreground,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(color: border),
    sliderTheme: SliderThemeData(
      activeTrackColor: secondary,
      thumbColor: secondary,
      inactiveTrackColor: secondaryContainer,
      activeTickMarkColor: scheme.onSecondary,
      inactiveTickMarkColor: scheme.onSecondaryContainer,
      overlayColor: secondary.withValues(alpha: .12),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) &&
                !states.contains(WidgetState.disabled)
            ? secondary
            : null,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) &&
                !states.contains(WidgetState.disabled)
            ? scheme.onSecondary
            : null,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: border),
      selectedColor: secondaryContainer,
      secondarySelectedColor: secondaryContainer,
      checkmarkColor: secondary,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? NightSurfaces.writing : scheme.surfaceContainerLowest,
      border: fieldBorder(border),
      enabledBorder: fieldBorder(border),
      focusedBorder: fieldBorder(secondary, width: 2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    cardTheme: CardThemeData(
      elevation: dark ? 0 : 2,
      shadowColor: dark ? Colors.black54 : foreground.withValues(alpha: .22),
      margin: EdgeInsets.zero,
      color: dark ? NightSurfaces.panel : raised,
      shape: cardShape,
    ),
    // ButtonStyleButton interpolates an entire nested ThemeData per button.
    // The appearance transition already blends those colors; InkWell still
    // animates hover, press and focus on the control itself.
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(animationDuration: Duration.zero),
    ),
    elevatedButtonTheme: const ElevatedButtonThemeData(
      style: ButtonStyle(animationDuration: Duration.zero),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: dark
          ? _nightFilledButton(scheme)
          : ButtonStyle(
              animationDuration: Duration.zero,
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.hovered) &&
                        !states.contains(WidgetState.disabled)
                    ? trim
                    : null,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.hovered) &&
                        !states.contains(WidgetState.disabled)
                    ? _onSolidColor(trim)
                    : null,
              ),
              shape: const WidgetStatePropertyAll(controlShape),
              side: WidgetStatePropertyAll(BorderSide(color: trim)),
            ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            shape: controlShape,
            side: BorderSide(color: border),
            animationDuration: Duration.zero,
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
        animationDuration: Duration.zero,
        shape: controlShape,
        foregroundColor: foreground,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        animationDuration: Duration.zero,
        shape: const WidgetStatePropertyAll(controlShape),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) &&
                  !states.contains(WidgetState.disabled)
              ? secondaryContainer
              : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return null;
          return states.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant;
        }),
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

// Keep the chosen hue and saturation, adjusting lightness only when the
// selected control's label would otherwise fall below 4.5:1 contrast.
Color _contrastingInk(Color seed, Color container, bool dark) {
  final background = container.computeLuminance() + .05;
  bool readable(Color color) {
    final ink = color.computeLuminance() + .05;
    return (dark ? ink / background : background / ink) >= 4.5;
  }

  if (readable(seed)) return seed;
  final hsl = HSLColor.fromColor(seed);
  var near = hsl.lightness;
  var far = dark ? 1.0 : 0.0;
  for (var i = 0; i < 8; i++) {
    final middle = (near + far) / 2;
    if (readable(hsl.withLightness(middle).toColor())) {
      far = middle;
    } else {
      near = middle;
    }
  }
  return hsl.withLightness(far).toColor();
}

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
    animationDuration: Duration.zero,
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
