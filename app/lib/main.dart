import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart';

import 'services/appearance_preferences.dart';
import 'services/updates/update_controller.dart';
import 'services/updates/update_host.dart';

import 'l10n/app_localizations.dart';
import 'theme/handwriting_theme.dart';
import 'widgets/appearance_transition.dart';
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
  late (Color, Color) themeSeeds;
  late ThemeData lightTheme, darkTheme;

  void resolveThemes() {
    themeSeeds = (appearance.color, appearance.secondaryColor);
    ThemeData resolve(Brightness brightness) => handwritingTheme(
      brightness,
      seedColor: appearance.color,
      secondaryColor: appearance.secondaryColor,
    );
    lightTheme = resolve(Brightness.light);
    darkTheme = resolve(Brightness.dark);
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb) semantics = WidgetsBinding.instance.ensureSemantics();
    locale = widget.locale ?? const Locale('zh');
    resolveThemes();
    appearance.addListener(refreshAppearance);
    appearance.restore();
    updates.initialize();
  }

  void refreshAppearance() {
    if (!mounted) return;
    if (themeSeeds != (appearance.color, appearance.secondaryColor)) {
      resolveThemes();
    }
    setState(() {});
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
    guideUnread: appearance.guideUnread,
    onGuideOpened: appearance.markGuideRead,
    toggleLocale: () => setState(
      () => locale = Locale(locale?.languageCode == 'zh' ? 'en' : 'zh'),
    ),
    themeColor: themeColor,
    secondaryThemeColor: appearance.secondaryColor,
    onPaletteChanged: appearance.setPalette,
    reduceMotion: appearance.reduceMotion,
    onReduceMotionChanged: appearance.setReduceMotion,
    themeMode: appearance.mode,
    onThemeModeChanged: appearance.setMode,
    toggleTheme: () {
      final dark = switch (appearance.mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark,
      };
      appearance.setMode(dark ? ThemeMode.light : ThemeMode.dark);
    },
  );

  @override
  Widget build(BuildContext context) => AppearanceTransition(
    appearance: (
      switch (appearance.mode) {
        ThemeMode.system => MediaQuery.platformBrightnessOf(context),
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
      },
      themeColor,
      appearance.secondaryColor,
    ),
    reduceMotion:
        appearance.reduceMotion || MediaQuery.disableAnimationsOf(context),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      themeAnimationStyle: AnimationStyle.noAnimation,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: appearance.mode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              MediaQuery.disableAnimationsOf(context) ||
              appearance.reduceMotion,
        ),
        child: handwritingBackdrop(context, child),
      ),
      home: workbench(),
      routes: {
        '/About': (_) => workbench(destination: 2),
        '/Feedback': (_) => workbench(destination: 2),
        '/Introduce': (_) => workbench(destination: 1),
        '/Login': (_) => workbench(destination: 2),
        '/Register': (_) => workbench(destination: 2),
      },
    ),
  );
}
