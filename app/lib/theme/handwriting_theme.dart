import 'package:flutter/material.dart';

/// Shared UI theme for startup, recovery screens and the workbench.
ThemeData handwritingTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF62833A),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'packages/handwriting_assets/LXGW WenKai',
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
  );
}
