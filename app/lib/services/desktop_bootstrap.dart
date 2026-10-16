import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/settings.dart';
import '../theme/handwriting_theme.dart';
import 'desktop_backend.dart';
import 'workspace.dart';
import 'mobile_api.dart';

export 'desktop_backend.dart' show usesDesktopBackend, usesMobileBackend;

class DesktopBootstrap extends StatefulWidget {
  const DesktopBootstrap({super.key, required this.builder});
  final Widget Function(Workspace) builder;

  @override
  State<DesktopBootstrap> createState() => _DesktopBootstrapState();
}

class _DesktopBootstrapState extends State<DesktopBootstrap> {
  DesktopBackend? backend;
  Workspace? workspace;
  AppLifecycleListener? lifecycle;
  bool failed = false, starting = false, closing = false;

  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        closing = true;
        await backend?.stop();
        if (workspace?.api case final MobileHandwritingApi api) {
          await api.cancelAll();
        }
        return AppExitResponse.exit;
      },
      onStateChange: (state) {
        if (state == AppLifecycleState.paused) {
          if (workspace?.api case final MobileHandwritingApi api) {
            unawaited(api.cancelAll());
          }
        }
      },
    );
    unawaited(start());
  }

  Future<void> start() async {
    if (starting) return;
    setState(() {
      starting = true;
      failed = false;
    });
    workspace?.dispose();
    workspace = null;
    await backend?.stop();
    final current = DesktopBackend();
    backend = current;
    Workspace? candidate;
    try {
      final api = usesMobileBackend
          ? await MobileHandwritingApi.bundled()
          : await current.start(
              dataDirectory: (await getApplicationSupportDirectory()).path,
            );
      if (!mounted || closing) {
        api.close();
        await current.stop();
        return;
      }
      final readyWorkspace = Workspace(
        api: api,
        managedBackend: true,
        settingsFactory: usesMobileBackend ? Settings.notebook : Settings.new,
      );
      candidate = readyWorkspace;
      await readyWorkspace.initialize();
      if (!mounted || closing || !readyWorkspace.connected) {
        readyWorkspace.dispose();
        await current.stop();
        if (mounted && !closing) {
          setState(() {
            failed = true;
            starting = false;
          });
        }
        return;
      }
      setState(() {
        workspace = readyWorkspace;
        failed = false;
        starting = false;
      });
      if (!usesMobileBackend) {
        unawaited(
          current.exited!.then((_) {
            if (mounted &&
                !closing &&
                !starting &&
                identical(backend, current)) {
              setState(() {
                failed = true;
              });
            }
          }),
        );
      }
    } catch (error) {
      candidate?.dispose();
      await current.stop();
      debugPrint('Bundled backend startup failed: $error');
      if (mounted && !closing) {
        setState(() {
          failed = true;
          starting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    closing = true;
    lifecycle?.dispose();
    workspace?.dispose();
    unawaited(backend?.stop() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (workspace != null && !failed) return widget.builder(workspace!);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: handwritingTheme(Brightness.light),
      darkTheme: handwritingTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: Builder(
        builder: (context) {
          final l = AppLocalizations.of(context)!;
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!failed) const CircularProgressIndicator(),
                    const SizedBox(height: 24),
                    Text(failed ? l.backendFailed : l.backendStarting),
                    if (failed) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: starting ? null : start,
                        child: Text(l.backendRetry),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
