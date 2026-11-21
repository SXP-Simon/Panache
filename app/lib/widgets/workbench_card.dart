import 'package:flutter/material.dart';

/// The workbench already transitions the complete appearance. Its panel frames
/// use the target card theme immediately, including the text, border and shadow.
class WorkbenchCard extends StatelessWidget {
  const WorkbenchCard({
    super.key,
    required this.child,
    this.margin,
    this.shape,
    this.color,
    this.clipBehavior,
  });

  final Widget child;
  final EdgeInsetsGeometry? margin;
  final ShapeBorder? shape;
  final Color? color;
  final Clip? clipBehavior;

  @override
  Widget build(BuildContext context) {
    final card = CardTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Padding(
        padding: margin ?? card.margin ?? EdgeInsets.zero,
        child: Material(
          type: MaterialType.card,
          animationDuration: Duration.zero,
          color: color ?? card.color ?? scheme.surfaceContainerLow,
          shadowColor: card.shadowColor ?? scheme.shadow,
          surfaceTintColor: card.surfaceTintColor ?? Colors.transparent,
          elevation: card.elevation ?? 0,
          shape: shape ?? card.shape,
          clipBehavior: clipBehavior ?? card.clipBehavior ?? Clip.none,
          child: child,
        ),
      ),
    );
  }
}
