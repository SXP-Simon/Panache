import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

Widget mcpConnectionTile(
  BuildContext context,
  BuildContext sheetContext,
  AppLocalizations l,
  String mcpConfig,
) => ListTile(
  key: const ValueKey('connect-ai-client'),
  leading: const Icon(Icons.hub_outlined),
  title: Text(l.connectAiClient),
  subtitle: Text(l.copyMcpConfig),
  trailing: const Icon(Icons.copy_outlined),
  onTap: () async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: mcpConfig));
    } on PlatformException {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l.mcpCopyFailed)));
      }
      return;
    }
    if (!sheetContext.mounted) return;
    Navigator.pop(sheetContext);
    messenger.showSnackBar(SnackBar(content: Text(l.mcpConfigCopied)));
  },
);

Widget themePreferenceTile(
  BuildContext context,
  AppLocalizations l, {
  required ThemeMode themeMode,
  required Future<bool> Function(ThemeMode)? onThemeModeChanged,
  required VoidCallback onToggleTheme,
}) => ListTile(
  leading: const Icon(Icons.contrast),
  title: Text(l.theme),
  subtitle: Text(switch (themeMode) {
    ThemeMode.system => l.themeSystem,
    ThemeMode.light => l.themeLight,
    ThemeMode.dark => l.themeDark,
  }),
  trailing: onThemeModeChanged == null
      ? null
      : PopupMenuButton<ThemeMode>(
          tooltip: l.chooseTheme,
          icon: const Icon(Icons.expand_more),
          initialValue: themeMode,
          itemBuilder: (_) => [
            for (final (mode, label) in [
              (ThemeMode.system, l.themeSystem),
              (ThemeMode.light, l.themeLight),
              (ThemeMode.dark, l.themeDark),
            ])
              CheckedPopupMenuItem(
                value: mode,
                checked: themeMode == mode,
                child: Text(label),
              ),
          ],
          onSelected: (value) {
            final nextBrightness = switch (value) {
              ThemeMode.system => MediaQuery.platformBrightnessOf(context),
              ThemeMode.light => Brightness.light,
              ThemeMode.dark => Brightness.dark,
            };
            if (Theme.of(context).brightness == nextBrightness) {
              Navigator.pop(context);
            } else {
              _dismissForAppearanceChange(context);
            }
            onThemeModeChanged(value);
          },
        ),
  onTap: () {
    _dismissForAppearanceChange(context);
    onToggleTheme();
  },
);

// The global appearance transition already blends the painted sheet into the
// new workbench. Retiring its route immediately avoids laying out and animating
// the outgoing sheet in a second theme on every frame of that same gesture.
void _dismissForAppearanceChange(BuildContext sheetContext) {
  Navigator.of(sheetContext).removeRoute(ModalRoute.of(sheetContext)!);
}
