import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/screens/dialogs/app_update_dialog.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/updates/update_controller.dart';
import 'package:handwriting_app/services/updates/update_model.dart';
import 'package:handwriting_app/services/updates/update_repository.dart';

final package = VerifiedPackage(
  ReleaseAsset(
    'Flutter-Panache-1.6.1-windows-x64.zip',
    Uri.parse(
      'https://github.com/SXP-Simon/Panache/releases/download/v1.6.1/Flutter-Panache-1.6.1-windows-x64.zip',
    ),
    128,
  ),
  'a' * 64,
  1006001,
);

class Repository extends UpdateRepository {
  @override
  Future<AppRelease> latest() async =>
      AppRelease('1.6.1', '* 更稳定的更新', [package.asset]);
  @override
  Future<VerifiedPackage> verifiedPackage(
    AppRelease release,
    UpdateTarget target,
  ) async => package;
}

class Prepared implements DesktopPreparedUpdate {
  Prepared(this.events);
  final List<String> events;
  @override
  void arm() => events.add('arm');
  @override
  Future<void> abort() async => events.add('abort');
}

class Host implements UpdateHost, DesktopUpdateHost {
  final events = <String>[];
  Completer<void>? downloadHold, prepareHold;
  bool failPrepare = false;
  @override
  Future<InstalledApp> installed() async =>
      const InstalledApp('1.6.0', UpdateTarget('windows', 'x64'));
  @override
  Future<DeployedApp?> deployedVersion() async => null;
  @override
  Future<String> download(
    VerifiedPackage package,
    DownloadCancellation cancellation,
    void Function(int, int) progress,
  ) async {
    events.add('download');
    await downloadHold?.future;
    cancellation.check();
    return '/cache/update.zip';
  }

  @override
  Future<DesktopPreparedUpdate> prepareRestart(
    String path,
    VerifiedPackage package,
    String version, {
    DownloadCancellation? cancellation,
  }) async {
    events.add('prepare');
    await prepareHold?.future;
    if (failPrepare) {
      throw const UpdateException(UpdateProblem.desktopUnavailable);
    }
    return Prepared(events);
  }

  @override
  Future<void> open(String path, int buildNumber) async => events.add('manual');
  @override
  void reload() {}
}

class ManualHost extends Host {
  @override
  Future<InstalledApp> installed() async => const InstalledApp(
    '1.6.0',
    UpdateTarget('windows', 'x64'),
    canRestartDesktop: false,
  );
}

Future<UpdateController> controller(Host host) async {
  final c = UpdateController(host: host, repository: Repository());
  c.installed = await host.installed();
  await c.check();
  return c;
}

void main() {
  test('one action downloads verifies prepares saves arms then exits, no second install click', () async {
    final host = Host();
    final actual = await controller(host);
    await actual.updateAndRestart(
      persist: () async {
        host.events.add('save');
        return true;
      },
      canRestart: () => true,
      requestExit: () async {
        host.events.add('exit');
        return true;
      },
    );
    expect(host.events, ['download', 'prepare', 'save', 'arm', 'exit']);
    expect(actual.phase, UpdatePhase.restarting);
    actual.dispose(); // Accepted process exit must leave the ARM pipe open until OS termination.
    expect(host.events.contains('abort'), false);
  });
  test(
    'save failure does not arm or quit and leaves current content running',
    () async {
      final host = Host();
      final actual = await controller(host);
      addTearDown(actual.dispose);
      await actual.updateAndRestart(
        persist: () async => false,
        canRestart: () => true,
        requestExit: () async {
          fail('must not quit');
        },
      );
      expect(host.events, ['download', 'prepare', 'abort']);
      expect(actual.problem, UpdateProblem.saveFailed);
      expect(actual.phase, UpdatePhase.ready);
    },
  );
  test(
    'cancelled OS exit revokes ARM, ready package can be used later',
    () async {
      final host = Host();
      final c = await controller(host);
      addTearDown(c.dispose);
      await c.updateAndRestart(
        persist: () async => true,
        canRestart: () => true,
        requestExit: () async => false,
      );
      expect(host.events, ['download', 'prepare', 'arm', 'abort']);
      expect(c.phase, UpdatePhase.ready);
      expect(c.problem, UpdateProblem.restartCancelled);
    },
  );
  test(
    'generation begun during preparation defers restart and preserves package',
    () async {
      final host = Host()..prepareHold = Completer<void>();
      final c = await controller(host);
      addTearDown(c.dispose);
      var idle = true;
      final action = c.updateAndRestart(
        persist: () async => true,
        canRestart: () => idle,
        requestExit: () async {
          fail('must wait for generation');
        },
      );
      await Future<void>.delayed(Duration.zero);
      idle = false;
      host.prepareHold!.complete();
      await action;
      expect(host.events, ['download', 'prepare', 'abort']);
      expect(c.phase, UpdatePhase.ready);
      expect(c.problem, UpdateProblem.restartDeferred);
    },
  );
  test('cancel while preparing prevents save and automatic exit', () async {
    final host = Host()..prepareHold = Completer<void>();
    final c = await controller(host);
    addTearDown(c.dispose);
    final action = c.updateAndRestart(
      persist: () async {
        fail('cancelled');
      },
      canRestart: () => true,
      requestExit: () async {
        fail('cancelled');
      },
    );
    await Future<void>.delayed(Duration.zero);
    c.cancel();
    host.prepareHold!.complete();
    await action;
    expect(host.events, ['download', 'prepare', 'abort']);
    expect(c.phase, UpdatePhase.ready);
  });
  test('cancel during download revokes complete restart chain', () async {
    final host = Host()..downloadHold = Completer<void>();
    final c = await controller(host);
    addTearDown(c.dispose);
    final action = c.updateAndRestart(
      persist: () async {
        fail('cancelled');
      },
      canRestart: () => true,
      requestExit: () async {
        fail('cancelled');
      },
    );
    await Future<void>.delayed(Duration.zero);
    c.cancel();
    host.downloadHold!.complete();
    await action;
    expect(host.events, ['download']);
    expect(c.phase, UpdatePhase.available);
  });
  test('unwritable or unsupported installation stays open with manual package fallback', () async {
    final host = Host()..failPrepare = true;
    final c = await controller(host);
    addTearDown(c.dispose);
    await c.updateAndRestart(
      persist: () async {
        fail('prepare did not complete');
      },
      canRestart: () => true,
      requestExit: () async {
        fail('do not exit');
      },
    );
    expect(c.phase, UpdatePhase.ready);
    expect(c.problem, UpdateProblem.desktopUnavailable);
    await c.open();
    expect(host.events.last, 'manual');
  });
  test('double click never starts two updater helpers', () async {
    final host = Host()..prepareHold = Completer<void>();
    final c = await controller(host);
    addTearDown(c.dispose);
    final action = c.updateAndRestart(
      persist: () async => true,
      canRestart: () => true,
      requestExit: () async => false,
    );
    await Future<void>.delayed(Duration.zero);
    await c.updateAndRestart(
      persist: () async => true,
      canRestart: () => true,
      requestExit: () async => false,
    );
    host.prepareHold!.complete();
    await action;
    expect(host.events.where((event) => event == 'prepare').length, 1);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'desktop update progress is visible and cancellable in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(760, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          final loader = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await loader.load();
          final text = FontLoader('packages/handwriting_assets/LXGW WenKai')
            ..addFont(
              rootBundle.load(
                'packages/handwriting_assets/font_assets/霞鹜文楷.ttf',
              ),
            );
          await text.load();
        });
        final host = Host()..prepareHold = Completer<void>();
        final c = await controller(host);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: handwritingTheme(brightness),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: AppUpdateProgressDialog(
                  controller: c,
                  onReload: () async {},
                  onRestart: () => c.updateAndRestart(
                    persist: () async => true,
                    canRestart: () => true,
                    requestExit: () async => false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.phase, UpdatePhase.preparing);
        expect(find.text('正在准备更新…'), findsOneWidget);
        expect(find.text('取消'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../preview_outputs/update-feature/flutter-desktop-${brightness.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        c.cancel();
        host.prepareHold!.complete();
        await tester.pump();
        expect(host.events.contains('arm'), false);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
  test('a known sandbox managed or legacy install never promises an automatic restart', () async {
    final host = ManualHost();
    final c = await controller(host);
    addTearDown(c.dispose);
    expect(c.desktop, true);
    expect(c.desktopAutomatic, false);
    await c.updateAndRestart(
      persist: () async {
        fail('manual install');
      },
      canRestart: () => true,
      requestExit: () async {
        fail('manual install');
      },
    );
    expect(host.events, isEmpty);
    await c.download();
    await c.open();
    expect(host.events, ['download', 'manual']);
  });
}
