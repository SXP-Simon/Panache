import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/mcp_connection_stub.dart'
    if (dart.library.io) '../services/mcp_connection_native.dart';
import '../theme/handwriting_theme.dart';
import '../theme/nouveau_ornament.dart';
import 'project_source_link.dart';
import 'theme_color_editor.dart';
import 'workbench_guide.dart';
import 'workbench_masthead.dart';
import 'workbench_motion.dart';
import 'workbench_navigation.dart';
import 'workbench_preferences.dart';

/// Adaptive app navigation and visible preference actions. Selection belongs to
/// the caller; this shell only presents callbacks and responsive navigation.
class WorkbenchShell extends StatelessWidget {
  const WorkbenchShell({
    super.key,
    this.themeColor = defaultThemeColor,
    this.secondaryThemeColor = defaultSecondaryThemeColor,
    this.onPaletteChanged,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.reduceMotion = false,
    this.onReduceMotionChanged,
    this.updateAvailable = false,
    this.guideUnread = false,
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
  final ThemeMode themeMode;
  final Future<bool> Function(ThemeMode)? onThemeModeChanged;
  final bool reduceMotion;
  final Future<bool> Function(bool)? onReduceMotionChanged;
  final Future<bool> Function(Color, Color)? onPaletteChanged;
  final bool updateAvailable, fineFullscreen, guideUnread;
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
    final size = WorkbenchWidth.from(MediaQuery.sizeOf(context).width);
    final keyboardDismissAt =
        !fineFullscreen && MediaQuery.viewInsetsOf(context).bottom > 0
        ? size
        : null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = theme.appBarTheme.foregroundColor ?? colors.onSurface;
    final palette =
        themeColor != defaultThemeColor ||
            secondaryThemeColor != defaultSecondaryThemeColor
        ? colors
        : null;
    void dismissKeyboard() => FocusScope.of(context).unfocus();
    return Scaffold(
      appBar: fineFullscreen
          ? null
          : workbenchMasthead(
              context,
              size: size,
              title: size == WorkbenchWidth.compact
                  ? [l.workspace, l.guide, l.about][destination]
                  : 'Panache',
              foreground: foreground,
              palette: palette,
              onDismissKeyboard: keyboardDismissAt == WorkbenchWidth.medium
                  ? dismissKeyboard
                  : null,
              actions: workbenchAppActions(
                l,
                size: size,
                guideUnread: guideUnread,
                updateAvailable: updateAvailable,
                foreground: foreground,
                unreadColor: palette?.secondary ?? NouveauColors.gold,
                onDestinationSelected: onDestinationSelected,
                onPreferences: () => preferencesSheet(context),
                onToggleLocale: onToggleLocale,
                onToggleTheme: onToggleTheme,
              ),
            ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                !fineFullscreen &&
                WorkbenchWidth.from(constraints.maxWidth) !=
                    WorkbenchWidth.compact;
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
            return colors.brightness == Brightness.dark
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: NightSurfaces.backdrop(colors.surface),
                    ),
                    child: content,
                  )
                : content;
          },
        ),
      ),
      floatingActionButton: keyboardDismissAt == WorkbenchWidth.compact
          ? FloatingActionButton.small(
              tooltip: l.dismissKeyboard,
              onPressed: dismissKeyboard,
              child: const Icon(Icons.keyboard_hide_outlined),
            )
          : null,
    );
  }

  Future<void> preferencesSheet(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    var motion = reduceMotion;
    final mcpConfig = desktopMcpConfig();
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
            child: ListView(
              key: const ValueKey('app-settings-list'),
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                ListTile(
                  title: Text(
                    l.appPreferences,
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                ),
                ListTile(
                  leading: GuideUnreadBadge(
                    unread: guideUnread,
                    child: const Icon(Icons.menu_book_outlined),
                  ),
                  title: Text(l.guide),
                  subtitle: guideUnread ? Text(l.guideUnread) : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onDestinationSelected(1);
                  },
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
                if (mcpConfig != null)
                  mcpConnectionTile(context, sheetContext, l, mcpConfig),
                ListTile(
                  leading: const Icon(Icons.translate),
                  title: Text(l.language),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onToggleLocale();
                  },
                ),
                themePreferenceTile(
                  sheetContext,
                  l,
                  themeMode: themeMode,
                  onThemeModeChanged: onThemeModeChanged,
                  onToggleTheme: onToggleTheme,
                ),
                ThemeColorEditor(
                  color: themeColor,
                  secondaryColor: secondaryThemeColor,
                  onPaletteChanged: onPaletteChanged,
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(l.about),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onDestinationSelected(2);
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
    );
  }
}
