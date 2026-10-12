import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart';

import 'l10n/app_localizations.dart';
import 'screens/workbench.dart';
import 'services/workspace.dart';
import 'services/desktop_bootstrap_stub.dart'
    if (dart.library.io) 'services/desktop_bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    usesDesktopBackend
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
  ThemeMode mode = ThemeMode.system;
  @override
  void initState() {
    super.initState();
    if (kIsWeb) semantics = WidgetsBinding.instance.ensureSemantics();
    locale = widget.locale ?? const Locale('zh');
  }

  @override
  void dispose() {
    semantics?.dispose();
    super.dispose();
  }

  ThemeData theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF007BFF),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
  }

  Widget workbench({int destination = 0}) => Workbench(
    workspace: widget.workspace,
    initialDestination: destination,
    toggleLocale: () => setState(
      () => locale = Locale(locale?.languageCode == 'zh' ? 'en' : 'zh'),
    ),
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
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
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
