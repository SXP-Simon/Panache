import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/screens/workbench.dart';
import 'package:handwriting_app/services/updates/update_controller.dart';
import 'package:handwriting_app/services/updates/update_model.dart';
import 'package:handwriting_app/services/updates/update_prompt_coordinator.dart';
import 'package:handwriting_app/services/updates/update_repository.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_updates_test.dart' show FakeHost, target, name, url, hash;
import 'workspace_test.dart' show ControlledApi, MemoryStorage;

class PromptRepository extends UpdateRepository {
  PromptRepository()
    : super(
        client: MockClient(
          (_) async => throw StateError('No network expected'),
        ),
      );
  bool offline = false, missing = false;
  @override
  Future<AppRelease> latest() async {
    if (offline) throw const UpdateException(UpdateProblem.network);
    return AppRelease(
      '1.7.0',
      '''### 改进
* 改善手写表格的对齐与布局
* 修复插图缩放时的显示问题
## 下载哪个包
* 不应出现在弹窗中的下载指南
''',
      missing
          ? []
          : [
              ReleaseAsset(name, url, 64 * 1048576),
              ReleaseAsset('$name.json', Uri.parse('$url.json'), 1024),
            ],
    );
  }

  @override
  Future<VerifiedPackage> verifiedPackage(
    AppRelease release,
    UpdateTarget target,
  ) async => VerifiedPackage(release.packageFor(target)!, hash, 1009000);
}

class PromptHost extends FakeHost {
  int reloads = 0;
  @override
  void reload() => reloads++;
}

Future<void> settlePolicy() =>
    Future<void>.delayed(const Duration(milliseconds: 12));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      UpdateController.autoCheckKey: true,
    }),
  );
  setUpAll(() async {
    final text = FontLoader('packages/handwriting_assets/LXGW WenKai');
    text.addFont(
      rootBundle.load('packages/handwriting_assets/font_assets/霞鹜文楷.ttf'),
    );
    await text.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  test(
    'automatic notices are once per identity and manual checks can reopen them',
    () async {
      final controller = UpdateController(
        host: PromptHost(),
        repository: PromptRepository(),
      );
      var prompts = 0;
      final coordinator = UpdatePromptCoordinator(
        controller: controller,
        ready: () => true,
        present: (_) async {
          prompts++;
        },
      );
      await controller.check(automatic: true);
      await settlePolicy();
      expect(prompts, 1);
      await controller.check(automatic: true);
      await settlePolicy();
      expect(prompts, 1);
      await controller.check();
      await settlePolicy();
      expect(prompts, 2);
      await controller.check(automatic: true);
      await settlePolicy();
      expect(prompts, 2);
      coordinator.dispose();
      controller.dispose();
    },
  );
  test(
    'a manual result is globally claimed once across multiple app routes',
    () async {
      final controller = UpdateController(
        host: PromptHost(),
        repository: PromptRepository(),
      );
      var prompts = 0;
      final coordinators = List.generate(
        2,
        (_) => UpdatePromptCoordinator(
          controller: controller,
          ready: () => true,
          present: (_) async {
            prompts++;
          },
        ),
      );
      await controller.check();
      await settlePolicy();
      expect(prompts, 1);
      await controller.check(automatic: true);
      await settlePolicy();
      expect(prompts, 1);
      for (final coordinator in coordinators) {
        coordinator.dispose();
      }
      controller.dispose();
    },
  );
  test('automatic web notices distinguish deployment identities', () async {
    final host = PromptHost()
      ..app = const InstalledApp('1.6.0', UpdateTarget('web', ''))
      ..deployment = const DeployedApp('1.7.0', 'build-one');
    final controller = UpdateController(
      host: host,
      repository: PromptRepository(),
    );
    var prompts = 0;
    final coordinator = UpdatePromptCoordinator(
      controller: controller,
      ready: () => true,
      present: (_) async {
        prompts++;
      },
    );
    await controller.check(automatic: true);
    await settlePolicy();
    await controller.check(automatic: true);
    await settlePolicy();
    expect(prompts, 1);
    host.deployment = const DeployedApp('1.7.0', 'build-two');
    await controller.check(automatic: true);
    await settlePolicy();
    expect(prompts, 2);
    coordinator.dispose();
    controller.dispose();
  });
  test(
    'busy routes wait and disposing pending or presented coordinators is safe',
    () async {
      final controller = UpdateController(
        host: PromptHost(),
        repository: PromptRepository(),
      );
      var ready = false, prompts = 0;
      final hold = Completer<void>();
      final coordinator = UpdatePromptCoordinator(
        controller: controller,
        ready: () => ready,
        retryDelay: const Duration(milliseconds: 3),
        present: (_) async {
          prompts++;
          await hold.future;
        },
      );
      await controller.check(automatic: true);
      await settlePolicy();
      expect(prompts, 0);
      ready = true;
      await settlePolicy();
      expect(prompts, 1);
      coordinator.dispose();
      hold.complete();
      await settlePolicy();
      await controller.check();
      await settlePolicy();
      expect(prompts, 1);
      controller.dispose();
    },
  );
  test(
    'downloads and later failures invalidate a queued available notice',
    () async {
      for (final fail in [false, true]) {
        final host = PromptHost()
          ..failure = fail ? UpdateProblem.network : null;
        final controller = UpdateController(
          host: host,
          repository: PromptRepository(),
        );
        var ready = false, prompts = 0;
        final coordinator = UpdatePromptCoordinator(
          controller: controller,
          ready: () => ready,
          retryDelay: const Duration(milliseconds: 3),
          present: (_) async {
            prompts++;
          },
        );
        await controller.check(automatic: true);
        await controller.download();
        ready = true;
        await settlePolicy();
        expect(prompts, 0);
        coordinator.dispose();
        controller.dispose();
      }
    },
  );
  test(
    'no update, offline and disabled startup checks never produce notices',
    () async {
      for (final mode in ['current', 'offline', 'disabled']) {
        final host = PromptHost();
        final repo = PromptRepository();
        if (mode == 'current') host.app = const InstalledApp('1.7.0', target);
        if (mode == 'offline') repo.offline = true;
        SharedPreferences.setMockInitialValues({
          UpdateController.autoCheckKey: mode != 'disabled',
        });
        final controller = UpdateController(host: host, repository: repo);
        var prompts = 0;
        final coordinator = UpdatePromptCoordinator(
          controller: controller,
          ready: () => true,
          present: (_) async {
            prompts++;
          },
        );
        await controller.initialize();
        await settlePolicy();
        expect(prompts, 0);
        coordinator.dispose();
        controller.dispose();
      }
    },
  );

  Future<void> mount(
    WidgetTester tester,
    UpdateController controller,
    Workspace workspace, {
    Brightness brightness = Brightness.light,
    GlobalKey? boundary,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: handwritingTheme(brightness),
          home: Workbench(
            workspace: workspace,
            updates: controller,
            toggleLocale: () {},
            toggleTheme: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'discovery displays visible changes, Later deduplicates, manual check reopens',
    (tester) async {
      final controller = UpdateController(
        host: PromptHost(),
        repository: PromptRepository(),
      );
      final workspace = Workspace(
        api: ControlledApi(),
        storage: MemoryStorage(),
      );
      await mount(tester, controller, workspace);
      await controller.check(automatic: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsOneWidget,
      );
      expect(find.text('改善手写表格的对齐与布局'), findsOneWidget);
      expect(find.textContaining('不应出现在'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('update-prompt-later')));
      await tester.pumpAndSettle();
      await controller.check(automatic: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsNothing,
      );
      await controller.check();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('update-prompt-later')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      workspace.dispose();
    },
  );
  testWidgets(
    'generation, background and an existing dialog delay the update prompt',
    (tester) async {
      final controller = UpdateController(
        host: PromptHost(),
        repository: PromptRepository(),
      );
      final workspace = Workspace(
        api: ControlledApi(),
        storage: MemoryStorage(),
      )..busy = true;
      await mount(tester, controller, workspace);
      await controller.check(automatic: true);
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsNothing,
      );
      workspace.busy = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsNothing,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(title: Text('其他操作')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsNothing,
      );
      Navigator.of(context).pop();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      workspace.dispose();
    },
  );
  testWidgets(
    'Update now keeps progress visible, cancellable and installation user initiated',
    (tester) async {
      final host = PromptHost()..hold = Completer<void>();
      final controller = UpdateController(
        host: host,
        repository: PromptRepository(),
      );
      final workspace = Workspace(
        api: ControlledApi(),
        storage: MemoryStorage(),
      );
      await mount(tester, controller, workspace);
      await controller.check();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('update-prompt-now')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('update-progress-dialog')),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('close-update-progress')),
            )
            .onPressed,
        isNull,
      );
      expect(host.opens, 0);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      host.hold!.complete();
      await tester.pumpAndSettle();
      expect(controller.problem, UpdateProblem.cancelled);
      await tester.tap(find.byKey(const ValueKey('close-update-progress')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-progress-dialog')),
        findsNothing,
      );
      expect(host.opens, 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      workspace.dispose();
    },
  );
  testWidgets(
    'web offers deployment refresh and saves before reloading without client notes',
    (tester) async {
      final host = PromptHost()
        ..app = const InstalledApp('1.6.0', UpdateTarget('web', ''))
        ..deployment = const DeployedApp('1.7.0', 'new-source');
      final controller = UpdateController(
        host: host,
        repository: PromptRepository(),
      );
      final storage = MemoryStorage();
      final workspace = Workspace(api: ControlledApi(), storage: storage)
        ..text = '保留的输入';
      await mount(tester, controller, workspace);
      await controller.check();
      await tester.pumpAndSettle();
      expect(find.text('改善手写表格的对齐与布局'), findsNothing);
      expect(find.byKey(const ValueKey('update-prompt-release')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('update-prompt-now')));
      await tester.pumpAndSettle();
      expect(host.reloads, 0);
      await tester.tap(find.widgetWithText(FilledButton, '保存并刷新网页'));
      await tester.pumpAndSettle();
      expect(host.reloads, 1);
      expect(storage.values['flutter.workspace'], contains('保留的输入'));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      workspace.dispose();
    },
  );
  testWidgets(
    'unsupported devices show release notes without an unusable update action',
    (tester) async {
      final host = PromptHost()
        ..app = const InstalledApp('1.6.0', UpdateTarget('ios', 'arm64'));
      final controller = UpdateController(
        host: host,
        repository: PromptRepository(),
      );
      final workspace = Workspace(
        api: ControlledApi(),
        storage: MemoryStorage(),
      );
      await mount(tester, controller, workspace);
      await controller.check();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-available-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('update-prompt-now')), findsNothing);
      expect(
        find.byKey(const ValueKey('update-prompt-release')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      workspace.dispose();
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'update discovery dialog is readable on a small ${brightness.name} screen',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = UpdateController(
          host: PromptHost(),
          repository: PromptRepository(),
        );
        final workspace = Workspace(
          api: ControlledApi(),
          storage: MemoryStorage(),
        );
        final boundary = GlobalKey();
        await mount(
          tester,
          controller,
          workspace,
          brightness: brightness,
          boundary: boundary,
        );
        await controller.check(automatic: true);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('update-prompt-now')), findsOneWidget);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../preview_outputs/update-feature/flutter-prompt-${brightness.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        workspace.dispose();
      },
    );
  }
}
