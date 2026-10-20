import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart';

import 'services/appearance_preferences.dart';
import 'services/updates/update_controller.dart';
import 'services/updates/update_host.dart';

import 'l10n/app_localizations.dart';
import 'theme/handwriting_theme.dart';
import 'screens/workbench.dart';
import 'services/workspace.dart';
import 'services/licenses.dart';
import 'services/desktop_bootstrap_stub.dart'
    if (dart.library.io) 'services/desktop_bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledLicenses();
  runApp(
    usesDesktopBackend || usesMobileBackend
        ? DesktopBootstrap(
            builder: (workspace) => HandwritingApp(workspace: workspace),
          )
        : const HandwritingApp(),
  );
}

class HandwritingApp extends StatefulWidget {
  const HandwritingApp({super.key, this.locale, this.workspace});
  final Locale? locale;
  final Workspace? workspace;
  @override
  State<HandwritingApp> createState() => _HandwritingAppState();
}

class _HandwritingAppState extends State<HandwritingApp> {
  SemanticsHandle? semantics;
  Locale? locale;
  final appearance = AppearancePreferences();
  late final updates = UpdateController(host: createUpdateHost());
  Color get themeColor => appearance.color;
  ThemeMode mode = ThemeMode.system;
  @override
  void initState() {
    super.initState();
    if (kIsWeb) semantics = WidgetsBinding.instance.ensureSemantics();
    locale = widget.locale ?? const Locale('zh');
    appearance.addListener(refreshAppearance);
    appearance.restore();
    updates.initialize();
  }

  void refreshAppearance() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appearance.removeListener(refreshAppearance);
    appearance.dispose();
    updates.dispose();
    semantics?.dispose();
    super.dispose();
  }

  Widget workbench({int destination = 0}) => Workbench(
    workspace: widget.workspace,
    updates: updates,
    initialDestination: destination,
    toggleLocale: () => setState(
      () => locale = Locale(locale?.languageCode == 'zh' ? 'en' : 'zh'),
    ),
    themeColor: themeColor,
    onThemeColorChanged: appearance.setColor,
    toggleTheme: () => setState(
      () => mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
    theme: handwritingTheme(Brightness.light, seedColor: themeColor),
    darkTheme: handwritingTheme(Brightness.dark, seedColor: themeColor),
    themeMode: mode,
    home: workbench(),
    routes: {
      '/About': (_) => workbench(destination: 2),
      '/Feedback': (_) => workbench(destination: 2),
      '/Introduce': (_) => workbench(destination: 1),
      '/Login': (_) => workbench(destination: 2),
      '/Register': (_) => workbench(destination: 2),
    },
  );
}
