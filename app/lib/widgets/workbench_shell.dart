import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'project_source_link.dart';
import 'workbench_motion.dart';
import 'theme_color_editor.dart';
import '../theme/handwriting_theme.dart';

/// Adaptive app navigation and visible preference actions. Selection belongs to
/// the caller; this shell only presents callbacks and responsive navigation.
class WorkbenchShell extends StatelessWidget {
  const WorkbenchShell({
    super.key,
    this.themeColor = defaultThemeColor,
    this.secondaryThemeColor = defaultSecondaryThemeColor,
    this.onSecondaryThemeColorChanged,
    this.onThemeColorChanged,
    this.reduceMotion = false,
    this.onReduceMotionChanged,
    this.updateAvailable = false,
    this.fineFullscreen = false,
    this.version = '',
    required this.destination,
    required this.onDestinationSelected,
    required this.connected,
    required this.managedBackend,
    required this.locked,
    required this.onConnection,
    required this.onToggleLocale,
    required this.onToggleTheme,
    required this.workspaceBuilder,
    required this.informationBuilder,
  });
  final Color themeColor, secondaryThemeColor;
  final bool reduceMotion;
  final Future<bool> Function(bool)? onReduceMotionChanged;
  final Future<bool> Function(Color)? onThemeColorChanged,
      onSecondaryThemeColorChanged;
  final bool updateAvailable, fineFullscreen;
  final String version;
  final int destination;
  final ValueChanged<int> onDestinationSelected;
  final bool connected, managedBackend, locked;
  final VoidCallback onConnection, onToggleLocale, onToggleTheme;
  final Widget Function(bool wide, double width) workspaceBuilder;
  final Widget Function() informationBuilder;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final showKeyboardDismiss =
        MediaQuery.sizeOf(context).width < 1100 &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final labels = [l.workspace, l.guide, l.about];
    return Scaffold(
      appBar: fineFullscreen
          ? null
          : MediaQuery.sizeOf(context).width < 900
          ? AppBar(
              title: Text(labels[destination]),
              automaticallyImplyLeading: false,
              actions: [
                TextButton.icon(
                  key: const ValueKey('app-preferences'),
                  onPressed: () => preferencesSheet(context),
                  icon: Badge(
                    isLabelVisible: updateAvailable,
                    child: const Icon(Icons.settings_outlined),
                  ),
                  label: Text(l.appPreferences),
                ),
              ],
            )
          : AppBar(
              title: const ProjectSourceLink(),
              bottom: showKeyboardDismiss
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(40),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => FocusScope.of(context).unfocus(),
                          icon: const Icon(Icons.keyboard_hide_outlined),
                          label: Text(l.dismissKeyboard),
                        ),
                      ),
                    )
                  : null,
              actions: [
                IconButton(
                  tooltip: l.guide,
                  onPressed: () => onDestinationSelected(1),
                  icon: const Icon(Icons.menu_book_outlined),
                ),
                IconButton(
                  tooltip: l.about,
                  onPressed: () => onDestinationSelected(2),
                  icon: Badge(
                    isLabelVisible: updateAvailable,
                    child: const Icon(Icons.info_outline),
                  ),
                ),
                if (MediaQuery.sizeOf(context).width < 1100) ...[
                  TextButton.icon(
                    key: const ValueKey('app-preferences'),
                    onPressed: () => preferencesSheet(context),
                    icon: const Icon(Icons.settings_outlined),
                    label: Text(l.appPreferences),
                  ),
                ] else ...[
                  TextButton.icon(
                    key: const ValueKey('app-preferences'),
                    onPressed: () => preferencesSheet(context),
                    icon: const Icon(Icons.palette_outlined),
                    label: Text(l.appPreferences),
                  ),
                  IconButton(
                    tooltip: l.language,
                    onPressed: onToggleLocale,
                    icon: const Icon(Icons.translate),
                  ),
                  IconButton(
                    tooltip: l.theme,
                    onPressed: onToggleTheme,
                    icon: const Icon(Icons.contrast),
                  ),
                ],
              ],
            ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = !fineFullscreen && constraints.maxWidth >= 900;
            final content = RetainedPaneSwitcher(
              index: destination == 0 ? 0 : 1,
              children: [
                workspaceBuilder(wide, constraints.maxWidth),
                Column(
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('back-to-workspace'),
                        onPressed: () => onDestinationSelected(0),
                        icon: const Icon(Icons.arrow_back),
                        label: Text(l.backToEditor),
                      ),
                    ),
                    Expanded(child: informationBuilder()),
                  ],
                ),
              ],
            );
            return content;
          },
        ),
      ),
      floatingActionButton:
          !fineFullscreen &&
              MediaQuery.sizeOf(context).width < 900 &&
              MediaQuery.viewInsetsOf(context).bottom > 0
          ? FloatingActionButton.small(
              tooltip: l.dismissKeyboard,
              onPressed: () => FocusScope.of(context).unfocus(),
              child: const Icon(Icons.keyboard_hide_outlined),
            )
          : null,
    );
  }

  Future<void> preferencesSheet(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    var motion = reduceMotion;
    return showModalBottomSheet<void>(
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  (MediaQuery.sizeOf(sheetContext).height -
                          MediaQuery.viewInsetsOf(sheetContext).bottom -
                          80)
                      .clamp(100, double.infinity),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      l.appPreferences,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  ListTile(
                    leading: Icon(
                      connected
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                    ),
                    title: Text(managedBackend ? l.localEngine : l.connection),
                    subtitle: Text(connected ? l.connected : l.disconnected),
                    onTap: locked || managedBackend
                        ? null
                        : () {
                            Navigator.pop(sheetContext);
                            onConnection();
                          },
                  ),
                  ListTile(
                    leading: const Icon(Icons.translate),
                    title: Text(l.language),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onToggleLocale();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.contrast),
                    title: Text(l.theme),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onToggleTheme();
                    },
                  ),
                  ThemeColorEditor(
                    color: themeColor,
                    secondaryColor: secondaryThemeColor,
                    onSecondaryChanged:
                        onSecondaryThemeColorChanged ?? (_) async => true,
                    onChanged: onThemeColorChanged ?? (_) async => true,
                  ),
                  for (final item in [
                    (1, l.guide, Icons.menu_book_outlined),
                    (2, l.about, Icons.info_outline),
                  ])
                    ListTile(
                      leading: Icon(item.$3),
                      title: Text(item.$2),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        onDestinationSelected(item.$1);
                      },
                    ),
                  StatefulBuilder(
                    builder: (context, update) => SwitchListTile(
                      key: const ValueKey('reduce-motion'),
                      secondary: const Icon(Icons.animation),
                      title: Text(l.reduceMotion),
                      subtitle: Text(l.reduceMotionHint),
                      value: motion,
                      onChanged: onReduceMotionChanged == null
                          ? null
                          : (value) async {
                              update(() => motion = value);
                              final saved = await onReduceMotionChanged!(value);
                              if (!saved && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l.motionSaveFailed)),
                                );
                              }
                            },
                    ),
                  ),
                  if (version.isNotEmpty)
                    ListTile(
                      title: Text(l.installedEngineVersion),
                      trailing: Semantics(
                        identifier: 'app-version',
                        child: Text('v$version'),
                      ),
                    ),
                  const ProjectSourceLink(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
