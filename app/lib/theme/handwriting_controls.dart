import 'package:flutter/material.dart';

import 'handwriting_palette.dart';

WidgetStateProperty<T?> _whenEnabled<T>(WidgetState state, T value) =>
    WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(state) && !states.contains(WidgetState.disabled)
          ? value
          : null,
    );

InputDecorationTheme handwritingInputTheme(ColorScheme scheme) {
  OutlineInputBorder fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecorationTheme(
    isDense: true,
    filled: true,
    fillColor: scheme.brightness == Brightness.dark
        ? NightSurfaces.writing
        : scheme.surfaceContainerLowest,
    border: fieldBorder(scheme.outlineVariant),
    enabledBorder: fieldBorder(scheme.outlineVariant),
    focusedBorder: fieldBorder(scheme.secondary, width: 2),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );
}

SwitchThemeData handwritingSwitchTheme(ColorScheme scheme) => SwitchThemeData(
  trackColor: _whenEnabled(WidgetState.selected, scheme.secondary),
  thumbColor: _whenEnabled(WidgetState.selected, scheme.onSecondary),
);

ButtonStyle handwritingFilledButton(HandwritingPalette palette) {
  final scheme = palette.scheme;
  return scheme.brightness == Brightness.dark
      ? _nightFilledButton(scheme)
      : ButtonStyle(
          animationDuration: Duration.zero,
          backgroundColor: _whenEnabled(WidgetState.hovered, palette.trim),
          foregroundColor: _whenEnabled(WidgetState.hovered, palette.onTrim),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          side: WidgetStatePropertyAll(BorderSide(color: palette.trim)),
        );
}

ButtonStyle handwritingOutlinedButton(ColorScheme scheme) =>
    OutlinedButton.styleFrom(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      animationDuration: Duration.zero,
      foregroundColor: scheme.onSurface,
    ).copyWith(
      side: scheme.brightness == Brightness.dark
          ? WidgetStateProperty.resolveWith(
              (states) => BorderSide(
                color: states.contains(WidgetState.disabled)
                    ? scheme.outlineVariant
                    : states.contains(WidgetState.focused)
                    ? scheme.secondary
                    : states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.pressed)
                    ? scheme.primary
                    : scheme.outline,
                width: states.contains(WidgetState.focused) ? 2 : 1,
              ),
            )
          : null,
    );

ButtonStyle handwritingSegmentedButton(ColorScheme scheme) => ButtonStyle(
  animationDuration: Duration.zero,
  shape: const WidgetStatePropertyAll(StadiumBorder()),
  backgroundColor: _whenEnabled(
    WidgetState.selected,
    scheme.secondaryContainer,
  ),
  foregroundColor: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) return null;
    return states.contains(WidgetState.selected)
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
  }),
);

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
