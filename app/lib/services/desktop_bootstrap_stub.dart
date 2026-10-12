import 'package:flutter/widgets.dart';

import 'workspace.dart';

bool get usesDesktopBackend => false;
bool get usesMobileBackend => false;

class DesktopBootstrap extends StatelessWidget {
  const DesktopBootstrap({super.key, required this.builder});
  final Widget Function(Workspace) builder;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
