import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/nouveau_ornament.dart';
import 'atelier_ornament.dart';
import 'project_source_link.dart';
import 'workbench_navigation.dart';

AppBar workbenchMasthead(
  BuildContext context, {
  required WorkbenchWidth size,
  required String title,
  required Color foreground,
  required ColorScheme? palette,
  required List<Widget> actions,
  required VoidCallback? onDismissKeyboard,
}) {
  final compact = size == WorkbenchWidth.compact;
  return AppBar(
    toolbarHeight: compact ? 64 : 84,
    titleSpacing: compact ? 6 : 18,
    automaticallyImplyLeading: false,
    centerTitle: false,
    surfaceTintColor: Colors.transparent,
    flexibleSpace: Stack(
      children: [
        if (size == WorkbenchWidth.expanded)
          Positioned(
            top: 0,
            bottom: 0,
            left: 425,
            right: 355,
            child: Align(
              alignment: Alignment.centerLeft,
              child: CustomPaint(
                size: const Size(340, 84),
                painter: AtelierTendrils(palette: palette),
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
          painter: AtelierIris(palette: palette),
        ),
        SizedBox(width: compact ? 7 : 12),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
              color: foreground,
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
            animationDuration: Duration.zero,
            color: foreground.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(32),
            child: ProjectSourceLink(foreground: foreground),
          ),
        ],
      ],
    ),
    bottom: onDismissKeyboard != null
        ? PreferredSize(
            preferredSize: const Size.fromHeight(40),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: foreground),
                onPressed: onDismissKeyboard,
                icon: const Icon(Icons.keyboard_hide_outlined),
                label: Text(AppLocalizations.of(context)!.dismissKeyboard),
              ),
            ),
          )
        : null,
    actions: [
      ...actions,
      SizedBox(width: compact ? 3 : 16),
    ],
  );
}
