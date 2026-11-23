import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/settings.dart';
import '../../models/upload.dart';
import '../paper_style_picker.dart';
import 'settings_fields.dart';

List<Widget> paperSettings(
  AppLocalizations l,
  SettingsFields fields, {
  required Upload? background,
  required VoidCallback onUploadBackground,
  required VoidCallback onRemoveBackground,
  required VoidCallback onDetectBackground,
  required VoidCallback? onAdjustBackground,
}) {
  final settings = fields.settings;
  return [
    settingsGroup('paper', l.paperBackground, Icons.description_outlined, [
      if (background == null) ...[
        SettingsFieldLabel(
          label: l.paperStyle,
          child: PaperStylePicker(
            value: settings.paperStyle,
            onChanged: fields.edited((style) => settings.paperStyle = style),
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (background != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            background.bytes,
            height: 120,
            fit: BoxFit.contain,
          ),
        ),
      FilledButton.tonalIcon(
        onPressed: fields.locked ? null : onUploadBackground,
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
                onPressed: fields.locked ? null : onAdjustBackground,
                icon: const Icon(Icons.crop_free),
                label: Text(l.paperAreaAction),
              ),
            TextButton.icon(
              key: const ValueKey('identify-paper'),
              onPressed: fields.locked ? null : onDetectBackground,
              icon: const Icon(Icons.format_line_spacing),
              label: Text(l.detectBackground),
            ),
            TextButton(
              onPressed: fields.locked ? null : onRemoveBackground,
              child: Text(l.remove),
            ),
          ],
        ),
      fields.settingSwitch(
        l.transparentPng,
        settings.transparentBackground,
        (value) => settings.transparentBackground = value,
        icon: Icons.texture,
      ),
      if (background != null) _paperCamera(l, fields),
    ], collapsible: false),
    settingsGroup('dimensions', l.paperSizeAndMargins, Icons.space_bar, [
      fields.parameterGrid(
        parameters.where(
          (p) =>
              p.key == 'width' ||
              p.key == 'height' ||
              p.key.endsWith('_margin'),
        ),
      ),
    ], collapsible: false),
  ];
}

Widget _paperCamera(AppLocalizations l, SettingsFields fields) => ExpansionTile(
  title: Text(l.paperCamera),
  children: [
    Text(l.paperCameraHint),
    for (final field in [
      ('camera_make', l.cameraMake),
      ('camera_model', l.cameraModel),
      ('camera_lens', l.cameraLens),
      ('camera_iso', 'ISO'),
    ])
      TextFormField(
        // Keep the field's scroll offset separate from the tile's expanded state.
        key: PageStorageKey('${field.$1}-${fields.settingsRevision}'),
        initialValue: fields.settings.camera[field.$1] ?? '',
        enabled: !fields.locked,
        maxLength: field.$1 == 'camera_iso' ? 5 : 96,
        keyboardType: field.$1 == 'camera_iso'
            ? TextInputType.number
            : TextInputType.text,
        decoration: InputDecoration(labelText: field.$2),
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: (value) => Settings.validCameraValue(field.$1, value ?? '')
            ? null
            : l.cameraValueHint,
        onChanged: (s) {
          if (s.isEmpty) {
            fields.settings.camera.remove(field.$1);
          } else {
            fields.settings.camera[field.$1] = s;
          }
          fields.onEdited();
        },
      ),
  ],
);
