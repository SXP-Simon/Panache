import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/settings.dart';
import '../services/api.dart';
import 'workbench_controls.dart';

/// Parameter presentation only. File, network and preset actions are supplied
/// by the workbench so this widget never owns asynchronous business operations.
class WorkbenchSettings extends StatelessWidget {
  const WorkbenchSettings({
    super.key,
    required this.settings,
    required this.fonts,
    required this.fontFile,
    required this.background,
    required this.settingsRevision,
    required this.locked,
    required this.onEdited,
    required this.onSelectFont,
    required this.onColorSelected,
    required this.onUploadFont,
    required this.onRemoveFont,
    required this.onDefaultPreset,
    required this.onSmallPreset,
    required this.onSavePreset,
    required this.onLoadPreset,
    required this.onExportPreset,
    required this.onImportPreset,
    required this.onUploadBackground,
    required this.onDetectBackground,
    required this.onRemoveBackground,
  });
  final Settings settings;
  final List<String> fonts;
  final Upload? fontFile, background;
  final int settingsRevision;
  final bool locked;
  final VoidCallback onEdited,
      onUploadFont,
      onRemoveFont,
      onDefaultPreset,
      onSmallPreset,
      onSavePreset,
      onLoadPreset,
      onExportPreset,
      onImportPreset,
      onUploadBackground,
      onDetectBackground,
      onRemoveBackground;
  final ValueChanged<String?> onSelectFont;
  final ValueChanged<String> onColorSelected;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return WorkbenchPanel(
      title: l.parameters,
      icon: Icons.tune,
      child: ListView(
        children: [
          Semantics(
            identifier: 'font-select',
            child: SettingsFieldLabel(
              label: l.font,
              child: DropdownButtonFormField<String>(
                key: ValueKey('font-${settings.font}-${fontFile?.name}'),
                initialValue: fonts.contains(settings.font)
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
                onChanged: locked
                    ? null
                    : (value) {
                        onSelectFont(value);
                      },
              ),
            ),
          ),
          TextButton.icon(
            onPressed: locked ? null : onUploadFont,
            icon: const Icon(Icons.upload),
            label: Text(fontFile?.name ?? l.uploadFont),
          ),
          if (fontFile != null)
            TextButton(
              onPressed: locked ? null : onRemoveFont,
              child: Text(l.remove),
            ),
          const Divider(),
          Text(l.presets, style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 4,
            children: [
              for (final preset in [
                (l.defaultPreset, onDefaultPreset),
                (l.smallPreset, onSmallPreset),
                (l.savePreset, onSavePreset),
                (l.loadPreset, onLoadPreset),
                (l.exportPreset, onExportPreset),
                (l.importPreset, onImportPreset),
              ])
                ActionChip(
                  label: Text(preset.$1),
                  onPressed: locked ? null : preset.$2,
                ),
            ],
          ),
          const Divider(),
          Text(l.background, style: Theme.of(context).textTheme.titleSmall),
          if (background != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                background!.bytes,
                height: 120,
                fit: BoxFit.contain,
              ),
            ),
          TextButton.icon(
            onPressed: locked ? null : onUploadBackground,
            icon: const Icon(Icons.image_outlined),
            label: Text(background?.name ?? l.uploadBackground),
          ),
          if (background != null)
            Wrap(
              children: [
                TextButton.icon(
                  key: const ValueKey('identify-paper'),
                  onPressed: locked ? null : onDetectBackground,
                  icon: const Icon(Icons.format_line_spacing),
                  label: Text(l.detectBackground),
                ),
                TextButton(
                  onPressed: locked ? null : onRemoveBackground,
                  child: Text(l.remove),
                ),
              ],
            ),
          const Divider(),
          ExpansionTile(
            title: Text(l.layout),
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            children: [parameterGrid(context, parameters.take(9).toList())],
          ),
          ExpansionTile(
            title: Text(l.variation),
            tilePadding: EdgeInsets.zero,
            children: [parameterGrid(context, parameters.sublist(9, 15))],
          ),
          ExpansionTile(
            title: Text(l.strike),
            tilePadding: EdgeInsets.zero,
            children: [parameterGrid(context, parameters.sublist(15))],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.underlined),
            value: settings.underlined,
            onChanged: locked
                ? null
                : (v) {
                    settings.underlined = v;
                    onEdited();
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.englishSpacing),
            value: settings.englishSpacing,
            onChanged: locked
                ? null
                : (v) {
                    settings.englishSpacing = v;
                    onEdited();
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.fullPreview),
            value: settings.fullPreview,
            onChanged: locked
                ? null
                : (v) {
                    settings.fullPreview = v;
                    onEdited();
                  },
          ),
          const Divider(),
          Text(l.ink),
          Wrap(
            spacing: 8,
            children: [
              for (final color in [
                (l.black, '(0, 0, 0, 255)'),
                (l.blue, '(0, 51, 153, 255)'),
                (l.red, '(180, 0, 0, 255)'),
              ])
                ChoiceChip(
                  label: Text(color.$1),
                  selected: settings.fill == color.$2,
                  onSelected: locked
                      ? null
                      : (_) {
                          onColorSelected(color.$2);
                        },
                ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsFieldLabel(
            label: l.customColor,
            child: TextFormField(
              key: ValueKey('fill-$settingsRevision'),
              initialValue: settings.fill,
              enabled: !locked,
              validator: (s) =>
                  RegExp(r'^\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)$')
                          .hasMatch(s ?? '') &&
                      (s!
                          .replaceAll(RegExp(r'[()\s]'), '')
                          .split(',')
                          .every((c) => int.parse(c) <= 255))
                  ? null
                  : l.validation,
              onChanged: (s) {
                settings.fill = s;
                onEdited();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget parameterGrid(BuildContext context, List<Parameter> fields) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final minWidth = 140 * MediaQuery.textScalerOf(context).scale(1);
          final columns = constraints.maxWidth >= minWidth * 2 + 8 ? 2 : 1;
          return Wrap(
            spacing: 8,
            runSpacing: 12,
            children: [
              for (final p in fields)
                SizedBox(
                  width: (constraints.maxWidth - 8 * (columns - 1)) / columns,
                  child: Semantics(
                    identifier: p.key,
                    child: SettingsFieldLabel(
                      label:
                          Localizations.localeOf(context).languageCode == 'en'
                          ? p.en
                          : p.zh,
                      child: TextFormField(
                        key: ValueKey('${p.key}-$settingsRevision'),
                        initialValue: settings.values[p.key],
                        enabled: !locked,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (s) => p.accepts(s)
                            ? null
                            : AppLocalizations.of(context)!.validation,
                        onChanged: (s) {
                          settings.values[p.key] = s;
                          onEdited();
                        },
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

/// Labels participate in layout rather than painting above an outlined field.
/// This keeps them inside scrolling and animated expansion clip boundaries.
class SettingsFieldLabel extends StatelessWidget {
  const SettingsFieldLabel({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );
}
