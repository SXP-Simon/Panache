import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/nouveau_ornament.dart';
import 'atelier_ornament.dart';
import 'project_source_link.dart';
import 'workbench_guide.dart';
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
    final showKeyboardDismiss =
        MediaQuery.sizeOf(context).width < 1100 &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final labels = [l.workspace, l.guide, l.about];
    final compact = MediaQuery.sizeOf(context).width < 900;
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final mastheadInk = dark ? colors.onSurface : NouveauColors.softIvory;
    final masthead = dark
        ? Color.alphaBlend(
            colors.secondary.withValues(alpha: .075),
            colors.surfaceContainerLow,
          )
        : Color.alphaBlend(
            const Color(0xff1b2918).withValues(alpha: .60),
            themeColor,
          );
    return Scaffold(
      appBar: fineFullscreen
          ? null
          : AppBar(
              toolbarHeight: compact ? 64 : 84,
              titleSpacing: compact ? 6 : 18,
              automaticallyImplyLeading: false,
              centerTitle: false,
              backgroundColor: masthead,
              foregroundColor: mastheadInk,
              surfaceTintColor: Colors.transparent,
              flexibleSpace: Stack(
                children: [
                  if (MediaQuery.sizeOf(context).width >= 1100)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      left: 425,
                      right: 355,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: CustomPaint(
                          size: const Size(340, 84),
                          painter: AtelierTendrils(
                            nightColors: dark ? colors : null,
                          ),
                        ),
                      ),
                    ),
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: NouveauWaveDivider(height: 7),
                  ),
                ],
              ),
              title: Row(
                children: [
                  CustomPaint(
                    size: Size.square(compact ? 48 : 78),
                    painter: AtelierIris(nightColors: dark ? colors : null),
                  ),
                  SizedBox(width: compact ? 7 : 12),
                  Flexible(
                    child: Text(
                      compact ? labels[destination] : 'Panache',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            color: mastheadInk,
                            fontSize: compact ? 22 : 37,
                            fontFamily: 'Playfair Display',
                            fontFamilyFallback: const [
                              'packages/handwriting_assets/LXGW WenKai',
                            ],
                            height: 1.1,
                            letterSpacing: compact ? 0 : 1,
                          ),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 20),
                    Material(
                      color: mastheadInk.withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(32),
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: colors.copyWith(primary: mastheadInk),
                          textButtonTheme: TextButtonThemeData(
                            style: TextButton.styleFrom(
                              foregroundColor: mastheadInk,
                            ),
                          ),
                        ),
                        child: const ProjectSourceLink(),
                      ),
                    ),
                  ],
                ],
              ),
              bottom: !compact && showKeyboardDismiss
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(40),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: mastheadInk,
                          ),
                          onPressed: () => FocusScope.of(context).unfocus(),
                          icon: const Icon(Icons.keyboard_hide_outlined),
                          label: Text(l.dismissKeyboard),
                        ),
                      ),
                    )
                  : null,
              actions: [
                if (!compact) ...[
                  IconButton(
                    key: const ValueKey('open-guide'),
                    tooltip: guideUnread
                        ? '${l.guide} · ${l.guideUnread}'
                        : l.guide,
                    onPressed: () => onDestinationSelected(1),
                    icon: GuideUnreadBadge(
                      unread: guideUnread,
                      child: const Icon(Icons.menu_book_outlined),
                    ),
                  ),
                  IconButton(
                    tooltip: l.about,
                    onPressed: () => onDestinationSelected(2),
                    icon: Badge(
                      isLabelVisible: updateAvailable,
                      child: const Icon(Icons.info_outline),
                    ),
                  ),
                ],
                Semantics(
                  hint: guideUnread && compact ? l.guideUnread : null,
                  child: TextButton.icon(
                    key: const ValueKey('app-preferences'),
                    style: TextButton.styleFrom(foregroundColor: mastheadInk),
                    onPressed: () => preferencesSheet(context),
                    icon: Badge(
                      isLabelVisible:
                          compact && (updateAvailable || guideUnread),
                      backgroundColor: updateAvailable
                          ? null
                          : dark
                          ? colors.secondary
                          : NouveauColors.gold,
                      child: const Icon(Icons.tune),
                    ),
                    label: Text(l.appPreferences),
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= 1100) ...[
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
                SizedBox(width: compact ? 3 : 16),
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
                              Navigator.pop(sheetContext);
                              onThemeModeChanged!(value);
                            },
                          ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onToggleTheme();
                    },
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
      ),
    );
  }
}
