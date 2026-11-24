import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/settings.dart';
import 'settings_fields.dart';

List<Widget> inkSettings(
  AppLocalizations l,
  SettingsFields fields,
  Widget? inkControls,
) {
  final settings = fields.settings;
  return [
    if (inkControls case final controls?)
      settingsGroup('ink', l.inkEffects, Icons.tune, [
        controls,
      ], collapsible: false),
    settingsGroup('variation', l.variation, Icons.gesture, [
      fields.parameterGrid(
        parameters.where(
          (p) =>
              p.key.endsWith('_sigma') && !p.key.startsWith('strikethrough_'),
        ),
      ),
    ], expanded: false),
    settingsGroup('strike', l.strike, Icons.strikethrough_s, [
      SwitchListTile(
        key: const ValueKey('enable-strikethrough'),
        contentPadding: EdgeInsets.zero,
        title: Text(l.enableStrikethrough),
        value: settings.strikethroughEnabled,
        onChanged: fields.edited(
          (enabled) => settings.setStrikethroughEnabled(enabled),
        ),
      ),
      fields.parameterGrid(
        parameters.where((p) => p.key.startsWith('strikethrough_')),
      ),
    ], expanded: false),
  ];
}
