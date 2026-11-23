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

/// Seed-derived colors used by both Material surfaces and custom controls.
class HandwritingPalette {
  const HandwritingPalette._(this.scheme, this.appBarBackground, this.trim);

  final ColorScheme scheme;
  final Color appBarBackground;
  final Color trim;
  Color get onTrim => _onSolidColor(trim);

  factory HandwritingPalette(
    Brightness brightness,
    Color seedColor,
    Color secondaryColor,
  ) {
    final dark = brightness == Brightness.dark;
    final hue = HSLColor.fromColor(seedColor);
    // Large surfaces share a neutral ramp. Hue adds only a trace of warmth or
    // coolness; saturated user-picked colors stay on small interactive elements.
    final saturation = hue.saturation.clamp(0.0, dark ? .035 : .085);
    Color surfaceTone(double daylight, double moonlight) => HSLColor.fromAHSL(
      1,
      hue.hue,
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
        ? (seedColor == defaultThemeColor
              ? NouveauColors.moonIris
              : base.primary)
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
    final trim = hue.withLightness(.60).toColor();
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

    return HandwritingPalette._(
      scheme,
      dark
          ? Color.alphaBlend(NightSurfaces.navigation, surface)
          : surfaceTone(.966, .222),
      trim,
    );
  }
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
