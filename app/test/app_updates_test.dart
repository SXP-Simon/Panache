import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/services/updates/update_controller.dart';
import 'package:handwriting_app/services/updates/update_model.dart';
import 'package:handwriting_app/services/updates/update_repository.dart';
import 'package:handwriting_app/services/updates/update_deployment.dart';
import 'package:handwriting_app/services/updates/update_notes.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/widgets/app_update_card.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriting_app/services/workspace.dart';

import 'workspace_test.dart' show MemoryStorage, ControlledApi;

const target = UpdateTarget('android', 'arm64-v8a');
const name = 'Flutter-Panache-1.7.0-android-arm64-v8a.apk';
final url = Uri.parse(
  'https://github.com/SXP-Simon/Panache/releases/download/v1.7.0/$name',
);
final hash = List.filled(64, 'a').join();

Map<String, Object> manifest() => {
  'schema_version': 1,
  'repository': releaseRepository,
  'release_tag': 'v1.7.0',
  'version': '1.7.0',
  'platform': target.platform,
  'file': name,
  'build_number': 1007000,
  'flutter_sha': List.filled(40, 'b').join(),
  'sha256': hash,
};
Map<String, Object> releaseData({
  String version = '1.7.0',
  bool withAsset = true,
}) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'body': '改进表格排版与应用更新。\nImprove table layout and app updates.',
  'assets': [
    if (withAsset)
      for (final suffix in ['', '.json'])
        {
          'name': '$name$suffix',
          'browser_download_url': '$url$suffix',
          'size': 64 * 1048576,
        },
  ],
};
UpdateRepository repository({
  Map<String, Object>? release,
  Map<String, Object>? metadata,
  int status = 200,
  bool invalid = false,
}) => UpdateRepository(
  client: MockClient(
    (request) async => http.Response(
      invalid
          ? '<html>'
          : jsonEncode(
              request.url.path.endsWith('.json')
                  ? metadata ?? manifest()
                  : release ?? releaseData(),
            ),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  ),
);

class FakeHost implements UpdateHost {
  InstalledApp app = const InstalledApp('1.6.0', target);
  DeployedApp? deployment;
  UpdateProblem? failure;
  int downloads = 0, opens = 0;
  bool cancelledAtEnd = false;
  Completer<void>? hold;
  @override
  Future<InstalledApp> installed() async => app;
  @override
  Future<DeployedApp?> deployedVersion() async => deployment;
  @override
  Future<String> download(
    VerifiedPackage package,
    DownloadCancellation cancellation,
    void Function(int, int) progress,
  ) async {
    downloads++;
    progress(20 * 1048576, 64 * 1048576);
    await hold?.future;
    if (failure != null) throw UpdateException(failure!);
    if (cancelledAtEnd) cancellation.cancel();
    cancellation.check();
    return '/private/cache/updates/$name';
  }

  @override
  Future<void> open(String path, int buildNumber) async {
    opens++;
    await hold?.future;
    if (failure != null) throw UpdateException(failure!);
  }

  @override
  void reload() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('release summary shows brief changes without scopes hashes or download guides', () {
    expect(
      summarizeReleaseNotes('''# 1.7.0
### Bug Fixes
* **fe/src:** 修复表格对齐 ([123abcd](https://github.com/SXP-Simon/Panache/commit/123abcd))
* **app:** 改善图片插入
## 下载哪个包
* Android 下载这个 APK
'''),
      ['修复表格对齐', '改善图片插入'],
    );
    expect(
      summarizeReleaseNotes(
        List.generate(8, (index) => '* Change $index').join('\n'),
      ).length,
      5,
    );
    expect(summarizeReleaseNotes('* one\n* one'), ['one']);
    expect(summarizeReleaseNotes('No user-facing changes.'), isEmpty);
  });
  test('Android follows the device ABI priority without guessing bitness', () {
    expect(androidUpdateTarget(['x86_64', 'arm64-v8a']).arch, 'x86_64');
    expect(androidUpdateTarget(['arm64-v8a', 'armeabi-v7a']).arch, 'arm64-v8a');
    expect(androidUpdateTarget(['armeabi-v7a']).arch, 'unknown');
  });
  test(
    'reload persistence explicitly reports failure and preserves dispose flush',
    () async {
      final storage = MemoryStorage()..fail = true;
      final workspace = Workspace(api: ControlledApi(), storage: storage)
        ..text = 'saved before reload';
      expect(await workspace.persistDraft(), isFalse);
      storage.fail = false;
      expect(await workspace.persistDraft(), isTrue);
      workspace.text = 'saved on exit';
      workspace.dispose();
      await workspace.persist();
      expect(
        jsonDecode(storage.values['flutter.workspace']!)['text'],
        'saved on exit',
      );
    },
  );
  test('web resolves deployment metadata against the HTML base rather than a route', () {
    final current = Uri.parse('https://example.com/panache/About');
    final endpoint = deployedVersionUri(
      Uri.parse('https://example.com/panache/'),
      current,
    );
    expect(endpoint.path, '/panache/version.json');
    expect(endpoint.queryParameters.containsKey('panache_update'), isTrue);
    expect(
      () => deployedVersionUri(Uri.parse('https://other.example/'), current),
      throwsA(isA<UpdateException>()),
    );
  });
  test(
    'deployment metadata is bounded and validates semantic versions',
    () async {
      final uri = Uri.parse('https://example.com/panache/version.json');
      for (final data in <Map<String, Object>>[
        {'version': '1.7.0', 'build_id': 'source-new'},
        {'version': 'unknown'},
        {'version': '1.7.0', 'build_id': List.filled(70000, 'x').join()},
      ]) {
        final client = MockClient(
          (_) async => http.Response(jsonEncode(data), 200),
        );
        if (data['build_id'] == 'source-new') {
          expect(
            (await loadDeployedVersion(client, uri)).buildId,
            'source-new',
          );
        } else {
          await expectLater(
            loadDeployedVersion(client, uri),
            throwsA(isA<UpdateException>()),
          );
        }
      }
    },
  );
  setUpAll(() async {
    final loader = FontLoader('packages/handwriting_assets/LXGW WenKai');
    loader.addFont(
      rootBundle.load('packages/handwriting_assets/font_assets/霞鹜文楷.ttf'),
    );
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(
    () => SharedPreferences.setMockInitialValues({
      UpdateController.autoCheckKey: false,
    }),
  );
  test(
    'semantic versions compare numerically and preserve prerelease order',
    () {
      expect(
        parseAppVersion('v1.10.0')!.compareTo(parseAppVersion('1.9.9')!),
        greaterThan(0),
      );
      expect(
        parseAppVersion('1.7.0')!.compareTo(parseAppVersion('1.7.0-rc.1')!),
        greaterThan(0),
      );
      for (final invalid in ['', 'unknown', '1.2', '1.2.3.4']) {
        expect(parseAppVersion(invalid), isNull);
      }
    },
  );
  test(
    'platform names select exact Flutter architecture packages only',
    () async {
      final release = await repository().latest();
      expect(release.packageFor(target)?.name, name);
      expect(
        release.packageFor(const UpdateTarget('android', 'x86_64')),
        isNull,
      );
      for (final platform in [
        const UpdateTarget('ios', 'arm64'),
        const UpdateTarget('windows', 'arm64'),
        const UpdateTarget('macos', 'x64'),
        const UpdateTarget('linux', 'arm64'),
      ]) {
        expect(platform.suffix, isNull);
      }
      expect(const UpdateTarget('windows', 'x64').suffix, 'windows-x64.zip');
      expect(const UpdateTarget('macos', 'arm64').suffix, 'macos-arm64.zip');
      expect(const UpdateTarget('linux', 'x64').suffix, 'linux-x64.tar.gz');
    },
  );
  test('legacy Android metadata derives the real ABI version code', () async {
    final repo = repository();
    final package = await repo.verifiedPackage(await repo.latest(), target);
    expect(package.buildNumber, 1009000);
    expect(package.sha256, hash);
  });
  test('explicit Android version code must match the ABI build code', () async {
    for (final code in [1009000, 1007000]) {
      final repo = repository(
        metadata: {...manifest(), 'android_version_code': code},
      );
      final release = await repo.latest();
      if (code == 1009000) {
        expect((await repo.verifiedPackage(release, target)).buildNumber, code);
      } else {
        await expectLater(
          repo.verifiedPackage(release, target),
          throwsA(isA<UpdateException>()),
        );
      }
    }
  });
  test(
    'manifest rejects wrong repository/version/platform/hash/file/schema',
    () async {
      for (final patch in <Map<String, Object>>[
        {'repository': 'other/project'},
        {'version': '1.6.0'},
        {'platform': 'android-x86_64'},
        {'sha256': 'bad'},
        {'file': '../../evil.apk'},
        {'schema_version': 9},
        {'flutter_sha': 'bad'},
        {'build_number': 0},
        {'release_tag': 'v1.6.0'},
      ]) {
        final repo = repository(metadata: {...manifest(), ...patch});
        await expectLater(
          repo.verifiedPackage(await repo.latest(), target),
          throwsA(
            isA<UpdateException>().having(
              (e) => e.problem,
              'problem',
              UpdateProblem.verification,
            ),
          ),
        );
      }
    },
  );
  test('untrusted asset URLs, duplicate assets and incomplete packages cannot install', () async {
    final bad = releaseData();
    bad['assets'] = [
      {
        'name': name,
        'browser_download_url': 'https://evil.example/$name',
        'size': 1,
      },
    ];
    await expectLater(
      repository(release: bad).latest(),
      throwsA(isA<UpdateException>()),
    );
    final repo = repository(release: releaseData(withAsset: false));
    await expectLater(
      repo.verifiedPackage(await repo.latest(), target),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.problem,
          'problem',
          UpdateProblem.missingAsset,
        ),
      ),
    );
    final duplicate = releaseData();
    duplicate['assets'] = [
      ...duplicate['assets'] as List,
      ...duplicate['assets'] as List,
    ];
    final duplicated = repository(release: duplicate);
    await expectLater(
      duplicated.verifiedPackage(await duplicated.latest(), target),
      throwsA(isA<UpdateException>()),
    );
  });
  test('network/rate limit/HTML/unstable response is reported instead of up to date', () async {
    for (final status in [403, 429, 500]) {
      await expectLater(
        repository(status: status).latest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.problem,
            'problem',
            status == 500 ? UpdateProblem.network : UpdateProblem.rateLimited,
          ),
        ),
      );
    }
    await expectLater(
      repository(invalid: true).latest(),
      throwsA(isA<UpdateException>()),
    );
    await expectLater(
      repository(release: {...releaseData(), 'prerelease': true}).latest(),
      throwsA(isA<UpdateException>()),
    );
  });
  test(
    'auto-check preference restores without downloading and survives a restart',
    () async {
      final host = FakeHost();
      final controller = UpdateController(host: host, repository: repository());
      await controller.initialize();
      expect(controller.phase, UpdatePhase.idle);
      await controller.setAutoCheck(true);
      final next = UpdateController(host: host, repository: repository());
      await next.initialize();
      expect(next.phase, UpdatePhase.available);
      expect(host.downloads, 0);
      expect(host.opens, 0);
      controller.dispose();
      next.dispose();
    },
  );
  test(
    'unknown versions, missing uploads and unsupported iOS stay distinct',
    () async {
      for (final entry in [
        ('', target, UpdateProblem.unknownVersion),
        (
          '1.6.0',
          const UpdateTarget('ios', 'arm64'),
          UpdateProblem.unsupportedPlatform,
        ),
        (
          '1.6.0',
          const UpdateTarget('android', 'x86_64'),
          UpdateProblem.missingAsset,
        ),
      ]) {
        final host = FakeHost()..app = InstalledApp(entry.$1, entry.$2);
        final controller = UpdateController(
          host: host,
          repository: repository(),
        );
        await controller.check();
        expect(controller.problem, entry.$3);
        expect(controller.phase, isNot(UpdatePhase.current));
        controller.dispose();
      }
    },
  );
  test('newer local and same semantic version are never downgraded', () async {
    for (final version in ['1.7.0', '1.8.0']) {
      final host = FakeHost()..app = InstalledApp(version, target);
      final controller = UpdateController(host: host, repository: repository());
      await controller.check();
      expect(controller.phase, UpdatePhase.current);
      controller.dispose();
    }
  });
  test(
    'download has progress, cancellation, retry and separate install consent',
    () async {
      final host = FakeHost()..hold = Completer<void>();
      final controller = UpdateController(host: host, repository: repository());
      await controller.check();
      final downloading = controller.download();
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, UpdatePhase.downloading);
      expect(controller.received, 20 * 1048576);
      await controller.download();
      expect(host.downloads, 1);
      controller.cancel();
      host.hold!.complete();
      await downloading;
      expect(controller.phase, UpdatePhase.available);
      expect(controller.problem, UpdateProblem.cancelled);
      expect(controller.downloadedPath, isNull);
      host.hold = null;
      await controller.download();
      expect(controller.phase, UpdatePhase.ready);
      expect(host.opens, 0);
      await controller.open();
      expect(host.opens, 1);
      controller.dispose();
    },
  );
  test(
    'verification failure never becomes installable; retry can recover',
    () async {
      final host = FakeHost()..failure = UpdateProblem.verification;
      final controller = UpdateController(host: host, repository: repository());
      await controller.check();
      await controller.download();
      await controller.open();
      expect(controller.phase, UpdatePhase.failed);
      expect(host.opens, 0);
      host.failure = null;
      await controller.download();
      expect(controller.phase, UpdatePhase.ready);
      host.hold = Completer<void>();
      final opening = controller.open();
      await controller.open();
      await controller.download();
      await controller.check();
      expect(host.opens, 1);
      expect(host.downloads, 2);
      host.hold!.complete();
      await opening;
      controller.dispose();
    },
  );
  test('web checks deployment independently from GitHub, including same-version builds', () async {
    final host = FakeHost()
      ..app = const InstalledApp('1.6.0', UpdateTarget('web', ''))
      ..deployment = const DeployedApp('1.7.0', 'new-source');
    final controller = UpdateController(
      host: host,
      repository: UpdateRepository(
        client: MockClient(
          (_) async => throw StateError('must not call GitHub'),
        ),
      ),
    );
    await controller.check();
    expect(controller.phase, UpdatePhase.available);
    expect(
      const DeployedApp('1.6.0', 'new').differsFrom('1.6.0', 'old'),
      isTrue,
    );
    expect(
      const DeployedApp('1.6.0', 'same').differsFrom('1.6.0', 'same'),
      isFalse,
    );
    expect(const DeployedApp('1.6.0', '').differsFrom('unknown', ''), isFalse);
    controller.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('small screen update card ${brightness.name} has no overflow', (
      tester,
    ) async {
      tester.view.reset();
      tester.view.physicalSize = const Size(430, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = FakeHost();
      final controller = UpdateController(host: host, repository: repository());
      await tester.runAsync(controller.check);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: handwritingTheme(brightness),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: handwritingTheme(brightness).colorScheme.surface,
                child: SingleChildScrollView(
                  child: AppUpdateCard(
                    controller: controller,
                    onReload: () async {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('download-update')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('download-update')));
        while (controller.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-update')), findsOneWidget);
      expect(host.opens, 0);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          '../preview_outputs/update-feature/flutter-${brightness.name}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      controller.dispose();
    });
  }
}
