import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/settings.dart';
import '../workbench_controls.dart';

Widget settingsGroup(
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

/// Shared binding for settings fields. File and navigation actions stay with
/// the section that presents them.
class SettingsFields {
  const SettingsFields(
    this.settings,
    this.settingsRevision,
    this.locked,
    this.onEdited,
  );

  final Settings settings;
  final int settingsRevision;
  final bool locked;
  final VoidCallback onEdited;

  ValueChanged<T>? edited<T>(ValueChanged<T> change) => locked
      ? null
      : (value) {
          change(value);
          onEdited();
        };

  Widget settingSwitch(
    String title,
    bool value,
    ValueChanged<bool> change, {
    IconData? icon,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    secondary: icon == null ? null : Icon(icon),
    value: value,
    onChanged: edited(change),
  );

  Widget parameterGrid(Iterable<Parameter> fields) => LayoutBuilder(
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
