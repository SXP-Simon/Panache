import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/settings.dart';
import '../../services/api.dart';
import '../ink_color_control.dart';
import '../ink_parameter_controls.dart';
import 'settings_fields.dart';

Widget fontSettings(
  AppLocalizations l,
  SettingsFields fields, {
  required List<String> fonts,
  required Upload? fontFile,
  required bool showInkColor,
  required ValueChanged<String?> onSelectFont,
  required ValueChanged<Color> onColorSelected,
  required VoidCallback onUploadFont,
  required VoidCallback onRemoveFont,
  required VoidCallback? onBrowseLocalFonts,
}) {
  final settings = fields.settings;
  return settingsGroup('font', l.fontChoices, Icons.font_download_outlined, [
    Semantics(
      identifier: 'font-select',
      child: SettingsFieldLabel(
        label: l.font,
        child: DropdownButtonFormField<String>(
          key: ValueKey('font-${settings.font}-${fontFile?.name}'),
          hint: Text(l.chooseBundledFont),
          initialValue: fontFile == null && fonts.contains(settings.font)
              ? settings.font
              : null,
          isExpanded: true,
          items: fonts
              .map(
                (f) => DropdownMenuItem(
                  value: f,
                  child: Text(f, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: fields.locked ? null : onSelectFont,
        ),
      ),
    ),
    const SizedBox(height: 6),
    if (fontFile != null)
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.font_download_outlined),
        title: Text(fontFile.name, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          tooltip: l.remove,
          onPressed: fields.locked ? null : onRemoveFont,
          icon: const Icon(Icons.close),
        ),
      ),
    if (onBrowseLocalFonts != null)
      FilledButton.tonalIcon(
        onPressed: fields.locked ? null : onBrowseLocalFonts,
        icon: const Icon(Icons.font_download_outlined),
        label: Text(l.localFonts),
      ),
    OutlinedButton.icon(
      onPressed: fields.locked ? null : onUploadFont,
      icon: const Icon(Icons.file_open_outlined),
      label: Text(l.importFontFile),
    ),
    const SizedBox(height: 10),
    SettingsFieldLabel(
      label: l.latinFont,
      child: DropdownButtonFormField<String>(
        key: ValueKey('latin-font-${fields.settingsRevision}'),
        isExpanded: true,
        initialValue: settings.latinFont ?? '',
        items: [
          DropdownMenuItem(value: '', child: Text(l.inheritLatinFont)),
          for (final entry in latinFonts.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: fields.edited(
          (value) => settings.latinFont = value == '' ? null : value,
        ),
      ),
    ),
    NumericSlider(
      label: l.latinFontScale,
      id: 'latin-font-scale',
      value: settings.latinScale.toDouble(),
      parameter: latinScaleParameter,
      unit: '%',
      onChanged: fields.edited((value) => settings.latinScale = value.round()),
    ),
    fields.settingSwitch(
      l.digitsLatin,
      settings.latinDigits,
      (value) => settings.latinDigits = value,
    ),
    if (showInkColor)
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: InkColorControl(
          key: const ValueKey('settings-ink-color'),
          color: Color(settings.inkLook.color),
          onChanged: fields.locked ? null : onColorSelected,
        ),
      ),
  ], collapsible: false);
}

Widget layoutPresetSettings(
  BuildContext context,
  AppLocalizations l,
  SettingsFields fields,
) {
  final settings = fields.settings;
  return settingsGroup('layout', l.layoutPreset, Icons.space_bar, [
    LayoutBuilder(
      builder: (context, constraints) => SegmentedButton<String>(
        key: const ValueKey('layout-style'),
        showSelectedIcon: false,
        direction:
            constraints.maxWidth < MediaQuery.textScalerOf(context).scale(170)
            ? Axis.vertical
            : Axis.horizontal,
        segments: [
          for (final (value, label) in [
            ('standard', l.layoutStandard),
            ('homework', l.layoutHomework),
          ])
            ButtonSegment(
              value: value,
              label: Text(
                label,
                style: settings.layoutStyle == value
                    ? const TextStyle(fontWeight: FontWeight.w700)
                    : null,
              ),
            ),
        ],
        selected: {settings.layoutStyle},
        onSelectionChanged: fields.edited(
          (selection) => settings.layoutStyle = selection.single,
        ),
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        l.layoutPresetHint,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  ], collapsible: false);
}

Widget spacingSettings(AppLocalizations l, SettingsFields fields) {
  final settings = fields.settings;
  return settingsGroup('spacing', l.sizeSpacing, Icons.format_size, [
    fields.parameterGrid(parameters.take(3)),
    fields.settingSwitch(
      l.indentFirstLine,
      settings.firstLineIndent,
      (value) => settings.firstLineIndent = value,
    ),
    fields.settingSwitch(
      l.fixedWidthText,
      settings.monospaced,
      (value) => settings.monospaced = value,
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l.englishSpacing),
      value: settings.englishSpacing,
      onChanged: fields.edited((v) => settings.englishSpacing = v),
    ),
  ], collapsible: false);
}
