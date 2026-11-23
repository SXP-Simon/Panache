import 'package:flutter/material.dart';

import 'handwriting_controls.dart';
import 'handwriting_palette.dart';

export 'handwriting_palette.dart'
    show NightSurfaces, defaultThemeColor, defaultSecondaryThemeColor;

/// An opaque base lets translucent dark surfaces composite consistently.
Widget handwritingBackdrop(BuildContext context, Widget? child) =>
    ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: child!);

/// Shared appearance for the workbench, startup and recovery screens.
ThemeData handwritingTheme(
  Brightness brightness, {
  Color seedColor = defaultThemeColor,
  Color secondaryColor = defaultSecondaryThemeColor,
}) {
  final palette = HandwritingPalette(brightness, seedColor, secondaryColor);
  final scheme = palette.scheme;
  final dark = brightness == Brightness.dark;
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(32),
    side: BorderSide(color: scheme.outlineVariant),
  );

  final theme = ThemeData(
    useMaterial3: true,
    fontFamily: 'packages/handwriting_assets/LXGW WenKai',
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarThemeData(
      backgroundColor: palette.appBarBackground,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.secondary,
      thumbColor: scheme.secondary,
      inactiveTrackColor: scheme.secondaryContainer,
      activeTickMarkColor: scheme.onSecondary,
      inactiveTickMarkColor: scheme.onSecondaryContainer,
      overlayColor: scheme.secondary.withValues(alpha: .12),
    ),
    switchTheme: handwritingSwitchTheme(scheme),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      selectedColor: scheme.secondaryContainer,
      secondarySelectedColor: scheme.secondaryContainer,
      checkmarkColor: scheme.secondary,
    ),
    inputDecorationTheme: handwritingInputTheme(scheme),
    cardTheme: CardThemeData(
      elevation: dark ? 0 : 2,
      shadowColor: dark
          ? Colors.black54
          : scheme.onSurface.withValues(alpha: .22),
      margin: EdgeInsets.zero,
      color: dark ? NightSurfaces.panel : scheme.surfaceContainer,
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
      style: handwritingFilledButton(palette),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: handwritingOutlinedButton(scheme),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        animationDuration: Duration.zero,
        shape: const StadiumBorder(),
        foregroundColor: scheme.onSurface,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: handwritingSegmentedButton(scheme),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainer,
      shape: cardShape,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      modalBackgroundColor: scheme.surfaceContainer,
      dragHandleColor: scheme.outline,
    ),
  );
  return theme.copyWith(
    textTheme: _handwritingText(theme.textTheme),
    navigationRailTheme: _navigationRail(scheme, theme.textTheme.labelMedium!),
  );
}

TextTheme _handwritingText(TextTheme text) {
  TextStyle? heading(TextStyle? style) => style?.copyWith(
    fontFamily: 'Playfair Display',
    fontFamilyFallback: const [
      'packages/handwriting_assets/LXGW WenKai',
      'Georgia',
      'serif',
    ],
  );
  return text.copyWith(
    displayLarge: heading(text.displayLarge)
        ?.copyWith(fontSize: 60, height: 1.1, fontWeight: FontWeight.w700),
    displayMedium: heading(text.displayMedium),
    displaySmall: heading(text.displaySmall),
    headlineSmall: heading(text.headlineSmall),
    headlineMedium: heading(text.headlineMedium),
    titleSmall: heading(text.titleSmall),
    headlineLarge: heading(text.headlineLarge)
        ?.copyWith(fontSize: 36, height: 1.25, fontWeight: FontWeight.w700),
    titleLarge: heading(text.titleLarge)
        ?.copyWith(fontSize: 26, height: 1.35, fontWeight: FontWeight.w700),
    titleMedium: heading(text.titleMedium)
        ?.copyWith(fontSize: 20, height: 1.25, fontWeight: FontWeight.w700),
    bodyLarge: text.bodyLarge?.copyWith(height: 1.8),
  );
}

NavigationRailThemeData _navigationRail(
  ColorScheme scheme,
  TextStyle railLabel,
) => NavigationRailThemeData(
  backgroundColor: scheme.surface,
  indicatorColor: scheme.primaryContainer,
  selectedIconTheme: IconThemeData(color: scheme.primary),
  unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
  selectedLabelTextStyle: railLabel.copyWith(
    color: scheme.onSurface,
    fontWeight: FontWeight.w600,
  ),
  unselectedLabelTextStyle: railLabel.copyWith(color: scheme.onSurfaceVariant),
);
