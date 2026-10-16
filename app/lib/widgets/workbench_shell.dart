import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'project_source_link.dart';

/// Adaptive app navigation and visible preference actions. Selection belongs to
/// the caller; this shell only presents callbacks and responsive navigation.
class WorkbenchShell extends StatelessWidget {
  const WorkbenchShell({
    super.key,
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
  final int destination;
  final ValueChanged<int> onDestinationSelected;
  final bool connected, managedBackend, locked;
  final VoidCallback onConnection, onToggleLocale, onToggleTheme;
  final Widget Function(bool wide, double width) workspaceBuilder;
  final Widget Function() informationBuilder;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final labels = [l.workspace, l.guide, l.about];
    const icons = [
      Icons.edit_note_rounded,
      Icons.menu_book_outlined,
      Icons.info_outline_rounded,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/branding/panache.png',
              key: const ValueKey('panache-brand-mark'),
              width: 32,
              height: 32,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l.appTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            MediaQuery.sizeOf(context).width < 1100 &&
                    MediaQuery.viewInsetsOf(context).bottom > 0
                ? 80
                : 40,
          ),
          child: Column(
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: ProjectSourceLink(),
                ),
              ),
              if (MediaQuery.sizeOf(context).width < 1100 &&
                  MediaQuery.viewInsetsOf(context).bottom > 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => FocusScope.of(context).unfocus(),
                    icon: const Icon(Icons.keyboard_hide_outlined),
                    label: Text(l.dismissKeyboard),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (MediaQuery.sizeOf(context).width < 1100) ...[
            TextButton.icon(
              key: const ValueKey('app-preferences'),
              onPressed: () => preferencesSheet(context),
              icon: const Icon(Icons.settings_outlined),
              label: Text(l.appPreferences),
            ),
          ] else ...[
            Tooltip(
              message: l.connection,
              child: TextButton.icon(
                onPressed: locked || managedBackend ? null : onConnection,
                icon: Icon(
                  connected
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                ),
                label: Text(managedBackend ? l.localEngine : l.connection),
              ),
            ),
            Tooltip(
              message: l.language,
              child: TextButton.icon(
                onPressed: onToggleLocale,
                icon: const Icon(Icons.translate),
                label: Text(l.language),
              ),
            ),
            Tooltip(
              message: l.theme,
              child: TextButton.icon(
                onPressed: onToggleTheme,
                icon: const Icon(Icons.contrast),
                label: Text(l.theme),
              ),
            ),
          ],
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final content = destination == 0
              ? workspaceBuilder(wide, constraints.maxWidth)
              : informationBuilder();
          return Row(
            children: [
              if (wide)
                NavigationRail(
                  selectedIndex: destination,
                  onDestinationSelected: onDestinationSelected,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationRailDestination(
                        icon: Icon(icons[i]),
                        label: Text(labels[i]),
                      ),
                  ],
                ),
              Expanded(child: content),
            ],
          );
        },
      ),
      bottomNavigationBar:
          MediaQuery.sizeOf(context).width < 900 &&
              MediaQuery.viewInsetsOf(context).bottom == 0
          ? NavigationBar(
              selectedIndex: destination,
              onDestinationSelected: onDestinationSelected,
              destinations: [
                for (var i = 0; i < labels.length; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
              ],
            )
          : null,
    );
  }

  Future<void> preferencesSheet(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        top: false,
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
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
