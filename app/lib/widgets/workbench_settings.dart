import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/settings.dart';
import '../services/api.dart';
import 'settings/ink_settings.dart';
import 'settings/layout_settings.dart';
import 'settings/paper_settings.dart';
import 'settings/settings_fields.dart';
import 'workbench_controls.dart';

export 'settings/settings_fields.dart' show SettingsFieldLabel;

enum SettingsSection {
  layout,
  paper,
  ink,
  presets;

  String label(AppLocalizations l) => switch (this) {
    layout => l.fontAndLayout,
    paper => l.mobilePaper,
    ink => l.inkTools,
    presets => l.presets,
  };

  IconData get icon => switch (this) {
    layout => Icons.font_download_outlined,
    paper => Icons.description_outlined,
    ink => Icons.gesture,
    presets => Icons.bookmarks_outlined,
  };
}

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
    this.onBrowseLocalFonts,
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
    this.activeSection,
    this.onSectionChanged,
    this.inkControls,
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
  final VoidCallback? onAdjustBackground, onBrowseLocalFonts;
  final SettingsSection? activeSection;
  final ValueChanged<SettingsSection>? onSectionChanged;
  final Widget? inkControls;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final fields = SettingsFields(settings, settingsRevision, locked, onEdited);
    bool show(SettingsSection group) =>
        activeSection == null || activeSection == group;
    return WorkbenchPanel(
      title: onSectionChanged == null
          ? activeSection?.label(l) ?? l.parameters
          : l.parameters,
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onSectionChanged case final change?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DropdownButtonFormField<SettingsSection>(
                key: const ValueKey('settings-section'),
                initialValue: activeSection,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.secondaryContainer,
                  prefixIcon: Icon(activeSection?.icon ?? Icons.tune),
                ),
                borderRadius: BorderRadius.circular(24),
                isExpanded: true,
                items: [
                  for (final section in SettingsSection.values)
                    DropdownMenuItem(
                      key: ValueKey('settings-section-${section.name}'),
                      value: section,
                      child: Text(
                        section.label(l),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) change(value);
                },
              ),
            ),
          Expanded(
            child: ListView(
              key: PageStorageKey(activeSection),
              children: [
                if (show(SettingsSection.layout)) ...[
                  fontSettings(
                    l,
                    fields,
                    fonts: fonts,
                    fontFile: fontFile,
                    showInkColor: activeSection == null,
                    onSelectFont: onSelectFont,
                    onColorSelected: onColorSelected,
                    onUploadFont: onUploadFont,
                    onRemoveFont: onRemoveFont,
                    onBrowseLocalFonts: onBrowseLocalFonts,
                  ),
                  layoutPresetSettings(context, l, fields),
                  spacingSettings(l, fields),
                ],
                if (show(SettingsSection.paper))
                  ...paperSettings(
                    l,
                    fields,
                    background: background,
                    onUploadBackground: onUploadBackground,
                    onRemoveBackground: onRemoveBackground,
                    onDetectBackground: onDetectBackground,
                    onAdjustBackground: onAdjustBackground,
                  ),
                if (show(SettingsSection.ink))
                  ...inkSettings(l, fields, inkControls),
                if (show(SettingsSection.presets))
                  settingsGroup(
                    'presets',
                    l.presets,
                    Icons.bookmarks_outlined,
                    [
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
                    ],
                    collapsible: false,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
