import 'package:flutter/material.dart';

class WorkbenchPanel extends StatelessWidget {
  const WorkbenchPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.actions = const [],
  });
  final String title;
  final IconData icon;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(
                    icon,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...actions,
            ],
          ),
          const Divider(height: 20),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

/// Presents both static settings sections and expandable groups.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.initiallyExpanded,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool? initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const corners = BorderRadius.all(Radius.circular(12));
    final expanded = initiallyExpanded;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card.outlined(
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: expanded == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Row(
                      children: [
                        Icon(icon, color: colors.onSurfaceVariant, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(title, style: theme.textTheme.titleSmall),
                        ),
                      ],
                    ),
                  ),
                  body,
                ],
              )
            : ExpansionTile(
                key: const PageStorageKey('expansion'),
                leading: Icon(icon, size: 19),
                title: Text(title),
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                initiallyExpanded: expanded,
                maintainState: true,
                collapsedShape: const RoundedRectangleBorder(
                  borderRadius: corners,
                ),
                shape: const RoundedRectangleBorder(borderRadius: corners),
                collapsedBackgroundColor: colors.secondaryContainer,
                collapsedIconColor: colors.onSecondaryContainer,
                collapsedTextColor: colors.onSecondaryContainer,
                iconColor: colors.primary,
                textColor: colors.onPrimaryContainer,
                expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
                    ? AnimationStyle.noAnimation
                    : null,
                children: [
                  Divider(
                    height: 1,
                    color: colors.primary.withValues(alpha: .55),
                  ),
                  body,
                ],
              ),
      ),
    );
  }
}

class EditorAction {
  const EditorAction(
    this.label,
    this.icon,
    this.onPressed, {
    this.description,
    this.identifier,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? description, identifier;
}

/// Presents names as well as icons; touch users never need to discover a tooltip.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.actions,
    required this.moreLabel,
    required this.hint,
  });
  final List<EditorAction> actions;
  final String moreLabel, hint;

  Widget button(EditorAction action) => Semantics(
    identifier: action.identifier,
    child: TextButton.icon(
      onPressed: action.onPressed,
      icon: Icon(action.icon, size: 20),
      label: Text(action.label),
    ),
  );

  Future<void> showTools(BuildContext context) => showModalBottomSheet<void>(
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .65,
      minChildSize: .35,
      maxChildSize: .9,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text(moreLabel, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(hint, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          for (final action in actions)
            ListTile(
              key: action.identifier == null
                  ? null
                  : ValueKey(action.identifier!),
              leading: Icon(action.icon),
              title: Text(action.label),
              subtitle: action.description == null
                  ? null
                  : Text(action.description!),
              enabled: action.onPressed != null,
              onTap: action.onPressed == null
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      action.onPressed!();
                    },
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (MediaQuery.sizeOf(context).width >= 1100 &&
          constraints.maxWidth >= 600) {
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: actions.map(button).toList(),
        );
      }
      return Wrap(
        children: [
          button(actions.first),
          TextButton.icon(
            key: const ValueKey('editor-tools'),
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              showTools(context);
            },
            icon: const Icon(Icons.edit_note),
            label: Text(moreLabel),
          ),
        ],
      );
    },
  );
}
