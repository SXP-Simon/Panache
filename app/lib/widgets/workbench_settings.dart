import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/settings.dart';
import '../services/api.dart';
import 'ink_color_control.dart';
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
    this.onAdjustBackground,
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
  final ValueChanged<Color> onColorSelected;
  final VoidCallback? onAdjustBackground;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return WorkbenchPanel(
      title: l.parameters,
      icon: Icons.tune,
      child: ListView(
        children: [
          section('font', l.fontInk, Icons.font_download_outlined, [
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
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
              onPressed: locked ? null : onUploadFont,
              icon: const Icon(Icons.upload),
              label: Text(
                fontFile?.name ?? l.uploadFont,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (fontFile != null)
              TextButton(
                onPressed: locked ? null : onRemoveFont,
                child: Text(l.remove),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: InkColorControl(
                key: const ValueKey('settings-ink-color'),
                color: Color(settings.inkLook.color),
                onChanged: locked ? null : onColorSelected,
              ),
            ),
          ], collapsible: false),
          section('layout', l.layoutPreset, Icons.space_bar, [
            LayoutBuilder(
              builder: (context, constraints) => SegmentedButton<String>(
                key: const ValueKey('layout-style'),
                showSelectedIcon: false,
                direction:
                    constraints.maxWidth <
                        MediaQuery.textScalerOf(context).scale(170)
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
                onSelectionChanged: locked
                    ? null
                    : (selection) {
                        settings.layoutStyle = selection.single;
                        onEdited();
                      },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.layoutPresetHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ], collapsible: false),
          section('spacing', l.sizeSpacing, Icons.format_size, [
            parameterGrid(context, parameters.take(3).toList()),
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
          ], collapsible: false),
          section('paper', l.paperBackground, Icons.description_outlined, [
            if (background != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  background!.bytes,
                  height: 120,
                  fit: BoxFit.contain,
                ),
              ),
            FilledButton.tonalIcon(
              onPressed: locked ? null : onUploadBackground,
              icon: const Icon(Icons.image_outlined),
              label: Text(
                background?.name ?? l.uploadBackground,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (background != null)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (onAdjustBackground != null)
                    FilledButton.tonalIcon(
                      key: const ValueKey('adjust-paper-area'),
                      onPressed: locked ? null : onAdjustBackground,
                      icon: const Icon(Icons.crop_free),
                      label: Text(l.paperAreaAction),
                    ),
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
          ], collapsible: false),
          section('dimensions', l.paperSizeAndMargins, Icons.space_bar, [
            parameterGrid(
              context,
              parameters
                  .where(
                    (p) =>
                        p.key == 'width' ||
                        p.key == 'height' ||
                        p.key.endsWith('_margin'),
                  )
                  .toList(),
            ),
          ]),
          section('variation', l.variation, Icons.gesture, [
            parameterGrid(
              context,
              parameters
                  .where(
                    (p) =>
                        p.key.endsWith('_sigma') &&
                        !p.key.startsWith('strikethrough_'),
                  )
                  .toList(),
            ),
          ], expanded: false),
          section('strike', l.strike, Icons.strikethrough_s, [
            SwitchListTile(
              key: const ValueKey('enable-strikethrough'),
              contentPadding: EdgeInsets.zero,
              title: Text(l.enableStrikethrough),
              value: settings.strikethroughEnabled,
              onChanged: locked
                  ? null
                  : (enabled) {
                      settings.setStrikethroughEnabled(enabled);
                      onEdited();
                    },
            ),
            parameterGrid(
              context,
              parameters
                  .where((p) => p.key.startsWith('strikethrough_'))
                  .toList(),
            ),
          ], expanded: false),
          section('presets', l.presets, Icons.bookmarks_outlined, [
            Wrap(
              spacing: 6,
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
          ], collapsible: false),
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
        ],
      ),
    );
  }

  Widget section(
    String id,
    String title,
    IconData icon,
    List<Widget> children, {
    bool expanded = false,
    bool collapsible = true,
  }) {
    return SettingsGroup(
      key: PageStorageKey('settings-$id'),
      title: title,
      icon: icon,
      initiallyExpanded: collapsible ? expanded : null,
      children: children,
    );
  }

  Widget parameterGrid(
    BuildContext context,
    List<Parameter> fields,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final minWidth = 140 * MediaQuery.textScalerOf(context).scale(1);
      final columns = constraints.maxWidth >= minWidth * 2 + 8 ? 2 : 1;
      return Wrap(
        spacing: 8,
        runSpacing: 12,
        children: [
          for (final p in fields)
            SizedBox(
              // TextField scroll offsets must not share the tile's stored bool.
              key: PageStorageKey('parameter-${p.key}'),
              width: (constraints.maxWidth - 8 * (columns - 1)) / columns,
              child: Semantics(
                identifier: p.key,
                child: SettingsFieldLabel(
                  label: Localizations.localeOf(context).languageCode == 'en'
                      ? p.en
                      : p.zh,
                  child: TextFormField(
                    key: ValueKey(
                      p.key.startsWith('strikethrough_')
                          ? '${p.key}-$settingsRevision-${settings.strikethroughEnabled}'
                          : '${p.key}-$settingsRevision',
                    ),
                    initialValue: settings.values[p.key],
                    enabled:
                        !locked &&
                        (!p.key.startsWith('strikethrough_') ||
                            settings.strikethroughEnabled),
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
