import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:panache_updater/installation.dart';
import 'package:panache_updater/client.dart';
import 'package:panache_updater/platform_files.dart';
import 'package:panache_updater/protocol.dart';
import 'package:panache_updater/process_identity.dart';
import 'package:panache_updater/transaction.dart';
import 'package:test/test.dart';

late Directory binaries;
late String helper, fakeApp, fakeServer;
String get platform => Platform.isWindows
    ? 'windows-x64'
    : Platform.isMacOS
    ? 'macos-arm64'
    : 'linux-x64';
String get extension => Platform.isWindows ? '.exe' : '';

class Fixture {
  Fixture(this.root, this.target, this.directory, this.plan, this.parent);
  final Process parent;
  Future<void> exitParent() async {
    await parent.stdin.close();
    await parent.exitCode;
  }

  final Directory root;
  final String target, directory;
  final UpdatePlan plan;
  String runtime(String version, int build) => Platform.isWindows
      ? p.join(target, 'versions', '$version-$build')
      : target;
  static Future<Fixture> create({String mode = 'healthy'}) async {
    final temporary = Directory.systemTemp.createTempSync('Panache 测试 space ');
    final root = Directory(temporary.resolveSymbolicLinksSync());
    final target = p.join(
      root.path,
      Platform.isMacOS ? 'Panache.app' : 'Panache',
    );
    final oldInfo = InstallInfo(
      platform,
      '1.6.0',
      1006000,
      Platform.isWindows ? 'windows-versioned' : 'bundle',
    );
    final nextInfo = InstallInfo(platform, '1.6.1', 1006001, oldInfo.layout);
    Future<void> bundle(String location, InstallInfo info, String mode) async {
      Directory(location).createSync(recursive: true);
      final runtime = Platform.isWindows
          ? p.join(location, 'versions', info.runtimeId)
          : location;
      Directory(p.dirname(p.join(runtime, info.executable)))
          .createSync(recursive: true);
      await File(fakeApp).copy(p.join(runtime, info.executable));
      setMode(p.join(runtime, info.executable), 0x1ed);
      final resources = Platform.isMacOS
          ? p.join(runtime, 'Contents', 'Resources')
          : runtime;
      Directory(resources).createSync(recursive: true);
      File(p.join(resources, 'mode')).writeAsStringSync(mode);
      final backend = p.join(
        runtime,
        Platform.isMacOS
            ? 'Contents/Resources/backend/handwriting-server'
            : 'backend/handwriting-server$extension',
      );
      Directory(p.dirname(backend)).createSync(recursive: true);
      await File(fakeServer).copy(backend);
      setMode(backend, 0x1ed);
      Directory(p.dirname(p.join(runtime, markerFor(platform))))
          .createSync(recursive: true);
      atomicFile(p.join(runtime, markerFor(platform)), info.toJson());
      if (Platform.isWindows) {
        atomicFile(p.join(location, markerName), info.toJson());
        atomicFile(p.join(location, 'active.json'), activeFor(info));
        atomicFile(p.join(location, 'last-good.json'), activeFor(info));
      }
      if (Platform.isMacOS) {
        File(p.join(location, 'Contents', 'Info.plist')).writeAsStringSync(
          '''<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.github.sxpsimon.handwriting</string><key>CFBundleExecutable</key><string>Panache</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>''',
        );
        final serverSigned = await Process.run('/usr/bin/codesign', [
          '--force',
          '--sign',
          '-',
          backend,
        ]);
        expect(serverSigned.exitCode, 0, reason: '${serverSigned.stderr}');
        final signed = await Process.run('/usr/bin/codesign', [
          '--force',
          '--sign',
          '-',
          location,
        ]);
        expect(signed.exitCode, 0, reason: '${signed.stderr}');
        final verified = await Process.run('/usr/bin/codesign', [
          '--verify',
          '--deep',
          '--strict',
          location,
        ]);
        expect(verified.exitCode, 0, reason: '${verified.stderr}');
      }
    }

    await bundle(target, oldInfo, 'old');
    final source = p.join(
      root.path,
      'source',
      Platform.isMacOS ? 'Panache.app' : 'Panache',
    );
    await bundle(source, nextInfo, mode);
    final updates = Directory(p.join(root.path, 'support', 'updates'))
      ..createSync(recursive: true);
    atomicFile(p.join(updates.path, 'updater-root.json'), {
      'schema': protocolVersion,
      'product': product,
    });
    final token = secureToken();
    final directory = Directory(p.join(updates.path, 'transactions', token))
      ..createSync(recursive: true);
    final download = Directory(p.join(updates.path, 'download-test'))
      ..createSync();
    final suffix = Platform.isLinux ? 'linux-x64.tar.gz' : '$platform.zip';
    final archivePath = p.join(download.path, 'Flutter-Panache-1.6.1-$suffix');
    final archive = Archive();
    await for (final item in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      final name =
          '${p.basename(source)}/${p.relative(item.path, from: source).split(p.separator).join('/')}';
      if (item is File) {
        final entry = ArchiveFile.bytes(name, await item.readAsBytes())
          ..mode = item.statSync().mode;
        archive.addFile(entry);
      }
    }
    if (Platform.isLinux) {
      File(archivePath).writeAsBytesSync(
        GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive)),
      );
    } else {
      File(archivePath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    }
    final runtime = Platform.isWindows
        ? p.join(target, 'versions', oldInfo.runtimeId)
        : target;
    final parent = await Process.start(p.join(runtime, oldInfo.executable), [
      '--hold',
    ]);
    parent.stderr.drain<void>().ignore();
    await parent.stdout.first;
    final plan = UpdatePlan(
      parent: ProcessIdentity.capture(parent.pid)!,
      token: token,
      target: target,
      archive: archivePath,
      sha256: await hashFile(archivePath),
      platform: platform,
      version: nextInfo.version,
      build: nextInfo.build,
      currentVersion: oldInfo.version,
      currentSha256: await hashFile(p.join(runtime, oldInfo.executable)),
    );
    atomicFile(p.join(directory.path, 'request.json'), plan.toJson());
    return Fixture(root, target, directory.path, plan, parent);
  }

  Future<void> dispose() async {
    parent.kill(ProcessSignal.sigkill);
    await parent.exitCode;
    try {
      await stopRecordedProcesses(directory, plan);
    } catch (_) {
      /* Test failure can precede a journal. */
    }
    for (var attempt = 0; ; attempt++) {
      try {
        root.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 30) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

Future<Process> startHelper(Fixture fixture) async {
  final process = await Process.start(helper, [
    '--prepare',
    fixture.directory,
    fixture.plan.token,
  ]);
  addTearDown(() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 10));
  });
  final ready = Completer<void>();
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line == 'PANACHE_UPDATE_READY ${fixture.plan.token}' &&
              !ready.isCompleted) {
            ready.complete();
          }
        },
        onDone: () {
          if (!ready.isCompleted) ready.completeError(StateError('$errors'));
        },
      );
  await ready.future.timeout(const Duration(seconds: 45));
  return process;
}

class FailingJournalTransaction extends UpdateTransaction {
  FailingJournalTransaction(super.directory, super.plan);
  @override
  void record(String phase, {String? reason}) {
    if ({'awaiting_health', 'rolling_back', 'rolled_back'}.contains(phase)) {
      throw const FileSystemException('injected full journal volume');
    }
    super.record(phase, reason: reason);
  }
}

void main() {
  setUpAll(() async {
    final temporary = Directory.systemTemp.createTempSync(
      'panache updater binaries ',
    );
    binaries = Directory(temporary.resolveSymbolicLinksSync());
    helper =
        Platform.environment['PANACHE_COMPILED_UPDATER'] ??
        p.join(binaries.path, 'helper$extension');
    fakeApp = p.join(binaries.path, 'app$extension');
    fakeServer = p.join(binaries.path, 'server$extension');
    for (final entry in {
      if (!Platform.environment.containsKey('PANACHE_COMPILED_UPDATER'))
        'bin/panache_updater.dart': helper,
      'test/fixtures/app.dart': fakeApp,
      'test/fixtures/server.dart': fakeServer,
    }.entries) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        entry.key,
        '-o',
        entry.value,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
  });
  tearDownAll(() {
    binaries.deleteSync(recursive: true);
  });
  test('compiled helper waits for ARM and parent EOF, then starts and commits a healthy app', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);
    final process = await startHelper(fixture);
    expect(currentInstall(fixture.plan).version, '1.6.0');
    process.stdin.writeln('ARM ${fixture.plan.token}');
    await process.stdin.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(currentInstall(fixture.plan).version, '1.6.0');
    await process.stdin.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(currentInstall(fixture.plan).version, '1.6.0');
    await fixture.exitParent();
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(currentInstall(fixture.plan).version, '1.6.1');
    expect(
      readJson(p.join(fixture.directory, 'journal.json'))['phase'],
      'committed',
    );
    expect(File(pendingPath(fixture.target)).existsSync(), isFalse);
  });
  test('ARM followed by cancelled exit leaves the old app and removes the staged version', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);
    final process = await startHelper(fixture);
    process.stdin.writeln('ARM ${fixture.plan.token}');
    process.stdin.writeln('ABORT ${fixture.plan.token}');
    await process.stdin.close();
    expect(fixture.plan.parent.matchesLive(), true);
    expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
    expect(currentInstall(fixture.plan).version, '1.6.0');
    expect(
      readJson(p.join(fixture.directory, 'journal.json'))['phase'],
      'cancelled',
    );
  });
  test('new process exits before health acknowledgement and old app is restarted, same version can retry', () async {
    final fixture = await Fixture.create(mode: 'crash');
    addTearDown(fixture.dispose);
    final transaction = UpdateTransaction(
      fixture.directory,
      fixture.plan,
      healthTimeout: const Duration(seconds: 2),
    );
    await transaction.prepare();
    await fixture.exitParent();
    await expectLater(
      transaction.applyAfterExit(),
      throwsA(isA<UpdaterFailure>()),
    );
    await transaction.rollback('restart_failed');
    expect(currentInstall(fixture.plan).version, '1.6.0');
    for (
      var i = 0;
      i < 50 && !File(p.join(fixture.root.path, 'reopened')).existsSync();
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      File(p.join(fixture.root.path, 'reopened')).readAsStringSync(),
      'restart_failed',
    );
    if (Platform.isMacOS) {
      final verified = await Process.run('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        fixture.target,
      ]);
      expect(verified.exitCode, 0, reason: '${verified.stderr}');
    }
    final token = secureToken();
    final directory = Directory(p.join(p.dirname(fixture.directory), token))
      ..createSync();
    final retryParent = await Process.start(
      p.join(fixture.runtime('1.6.0', 1006000), executableFor(platform)),
      ['--hold'],
    );
    retryParent.stderr.drain<void>().ignore();
    await retryParent.stdout.first;
    addTearDown(() async {
      retryParent.kill();
      await retryParent.exitCode;
    });
    final plan = UpdatePlan(
      parent: ProcessIdentity.capture(retryParent.pid)!,
      token: token,
      target: fixture.plan.target,
      archive: fixture.plan.archive,
      sha256: fixture.plan.sha256,
      platform: fixture.plan.platform,
      version: fixture.plan.version,
      build: fixture.plan.build,
      currentVersion: fixture.plan.currentVersion,
      currentSha256: fixture.plan.currentSha256,
    );
    atomicFile(p.join(directory.path, 'request.json'), plan.toJson());
    final retry = UpdateTransaction(directory.path, plan);
    await retry.prepare();
    await retry.abort();
  });
  test('wrong acknowledgement times out, stops exact new process, and restores previous version', () async {
    final fixture = await Fixture.create(mode: 'bad-ack');
    addTearDown(fixture.dispose);
    final transaction = UpdateTransaction(
      fixture.directory,
      fixture.plan,
      healthTimeout: const Duration(milliseconds: 500),
    );
    await transaction.prepare();
    await fixture.exitParent();
    await expectLater(
      transaction.applyAfterExit(),
      throwsA(
        predicate((e) => e is UpdaterFailure && e.code == 'health_timeout'),
      ),
    );
    final identity = ProcessIdentity.fromJson(
      readJson(p.join(fixture.directory, 'journal.json'))['new_process']
          as Map<String, dynamic>,
    );
    expect(identity.matchesLive(), isTrue);
    await transaction.rollback('health_timeout');
    expect(identity.matchesLive(), isFalse);
    expect(currentInstall(fixture.plan).version, '1.6.0');
  });
  test('archive bytes changed after planning are rejected before replacing anything', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);
    File(fixture.plan.archive).writeAsStringSync('tampered');
    final transaction = UpdateTransaction(fixture.directory, fixture.plan);
    await expectLater(
      transaction.prepare(),
      throwsA(
        predicate((e) => e is UpdaterFailure && e.code == 'package_changed'),
      ),
    );
    await transaction.abort();
    expect(currentInstall(fixture.plan).version, '1.6.0');
  });
  test('journal failure after process start still stops new app and restores binaries', () async {
    final fixture = await Fixture.create(mode: 'bad-ack');
    addTearDown(fixture.dispose);
    final transaction = FailingJournalTransaction(
      fixture.directory,
      fixture.plan,
    );
    await transaction.prepare();
    await fixture.exitParent();
    await expectLater(
      transaction.applyAfterExit(),
      throwsA(isA<FileSystemException>()),
    );
    await transaction.rollback('storage');
    expect(currentInstall(fixture.plan).version, '1.6.0');
    expect(File(pendingPath(fixture.target)).existsSync(), false);
  });
  test('hard helper termination keeps a launchable entry and a cold recovery restores last good', () async {
    final fixture = await Fixture.create(mode: 'bad-ack');
    addTearDown(fixture.dispose);
    final process = await startHelper(fixture);
    process.stdin.writeln('ARM ${fixture.plan.token}');
    await process.stdin.close();
    await fixture.exitParent();
    for (var i = 0; i < 100; i++) {
      try {
        final phase = readJson(
          p.join(fixture.directory, 'journal.json'),
        )['phase'];
        if (phase == 'awaiting_health') break;
      } on FileSystemException {
        /* Atomic journal replacement may hold a brief Windows share lock. */
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(currentInstall(fixture.plan).version, '1.6.1');
    expect(
      File(
        p.join(
          Platform.isWindows
              ? windowsRuntime(
                  fixture.target,
                  readJson(p.join(fixture.target, 'active.json')),
                )
              : fixture.target,
          executableFor(platform),
        ),
      ).existsSync(),
      true,
    );
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    if (Platform.isWindows) {
      await launchWindows(fixture.target);
    } else {
      await UpdateTransaction(fixture.directory, fixture.plan).recover();
    }
    expect(currentInstall(fixture.plan).version, '1.6.0');
    expect(File(pendingPath(fixture.target)).existsSync(), false);
  });
  test(
    'a competing updater never replaces or unlocks an active transaction',
    () async {
      final fixture = await Fixture.create();
      addTearDown(fixture.dispose);
      final first = await startHelper(fixture);
      final competing = await Process.run(helper, [
        '--prepare',
        fixture.directory,
        fixture.plan.token,
      ]);
      expect(competing.exitCode, 1);
      expect(currentInstall(fixture.plan).version, '1.6.0');
      first.stdin.writeln('ABORT ${fixture.plan.token}');
      await first.stdin.close();
      await first.exitCode;
    },
  );
  test('client preparation can be cancelled before READY without arming or quitting', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);
    await expectLater(
      launchPreparedHelper(
        helper,
        fixture.directory,
        fixture.plan.token,
        onStarted: (session) => unawaited(session.abort()),
      ),
      throwsA(predicate((e) => e is UpdaterFailure && e.code == 'cancelled')),
    );
    for (var i = 0; i < 200; i++) {
      try {
        if (readJson(p.join(fixture.directory, 'journal.json'))['phase'] ==
            'cancelled') {
          break;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(currentInstall(fixture.plan).version, '1.6.0');
    expect(
      readJson(p.join(fixture.directory, 'journal.json'))['phase'],
      'cancelled',
    );
  });
  test('installer waits for the old owned Rust sidecar stdin lifecycle before switching', () async {
    final fixture = await Fixture.create(mode: 'healthy-sidecar');
    addTearDown(fixture.dispose);
    final runtime = fixture.runtime('1.6.0', 1006000);
    final server = p.join(
      runtime,
      Platform.isMacOS
          ? 'Contents/Resources/backend/handwriting-server'
          : 'backend/handwriting-server$extension',
    );
    final backend = await Process.start(server, []);
    backend.stderr.drain<void>().ignore();
    await backend.stdout.first;
    addTearDown(() async {
      backend.kill();
      await backend.exitCode;
    });
    atomicFile(p.join(fixture.directory, 'request.json'), {
      ...fixture.plan.toJson(),
      'sidecar_pid': backend.pid,
    });
    final process = await startHelper(fixture);
    process.stdin.writeln('ARM ${fixture.plan.token}');
    await process.stdin.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(currentInstall(fixture.plan).version, '1.6.0');
    await fixture.exitParent();
    await backend.stdin.close();
    await backend.exitCode;
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(currentInstall(fixture.plan).version, '1.6.1');
    final sidecar = ProcessIdentity.fromJson(
      readJson(p.join(fixture.directory, 'started.json'))['sidecar']
          as Map<String, dynamic>,
    );
    expect(sidecar.matchesLive(), true);
    await stopRecordedProcesses(fixture.directory, fixture.plan);
    expect(await sidecar.waitGone(), true);
  });
  test(
    'a post-exit pointer write failure still reopens the unchanged old app',
    () async {
      if (!Platform.isWindows) return;
      final fixture = await Fixture.create();
      addTearDown(fixture.dispose);
      final process = await startHelper(fixture);
      final attributes = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, int)
          >('SetFileAttributesW');
      final path = p.join(fixture.target, 'active.json').toNativeUtf16();
      try {
        expect(attributes(path, 1), 1);
        process.stdin.writeln('ARM ${fixture.plan.token}');
        await process.stdin.close();
        await fixture.exitParent();
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 1);
        expect(currentInstall(fixture.plan).version, '1.6.0');
        for (
          var i = 0;
          i < 100 && !File(p.join(fixture.root.path, 'reopened')).existsSync();
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(
          File(p.join(fixture.root.path, 'reopened')).readAsStringSync(),
          'atomic_write_failed',
        );
      } finally {
        attributes(path, 128);
        calloc.free(path);
      }
    },
  );

  test(
    'sandboxed mac bundles are rejected before the parent is asked to quit',
    () async {
      if (!Platform.isMacOS) return;
      final fixture = await Fixture.create();
      addTearDown(fixture.dispose);
      final entitlement = File(p.join(fixture.root.path, 'sandbox.plist'))
        ..writeAsStringSync(
          '<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>',
        );
      final signed = await Process.run('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        '--entitlements',
        entitlement.path,
        fixture.target,
      ]);
      expect(signed.exitCode, 0, reason: '${signed.stderr}');
      final result = await Process.run(helper, [
        '--prepare',
        fixture.directory,
        fixture.plan.token,
      ]);
      expect(result.exitCode, 1);
      expect('${result.stderr}', contains('sandbox_installation'));
      expect(currentInstall(fixture.plan).version, '1.6.0');
    },
  );
  test('a second live GUI at the same exact executable blocks prepare without terminating either', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);
    final second = await Process.start(fixture.plan.parent.executable, [
      '--hold',
    ]);
    second.stderr.drain<void>().ignore();
    await second.stdout.first;
    addTearDown(() async {
      second.kill();
      await second.exitCode;
    });
    final identity = ProcessIdentity.capture(second.pid)!;
    final found = ProcessIdentity.matchingExecutable(
      fixture.plan.parent.executable,
    );
    expect(
      found.map((item) => item.pid),
      containsAll([fixture.parent.pid, second.pid]),
    );
    final result = await Process.run(helper, [
      '--prepare',
      fixture.directory,
      fixture.plan.token,
    ]);
    expect(result.exitCode, 1);
    expect('${result.stderr}', contains('another_instance_running'));
    await expectLater(
      launchPreparedHelper(helper, fixture.directory, fixture.plan.token),
      throwsA(
        predicate(
          (e) => e is UpdaterFailure && e.code == 'another_instance_running',
        ),
      ),
    );
    expect(fixture.plan.parent.matchesLive(), true);
    expect(identity.matchesLive(), true);
    expect(currentInstall(fixture.plan).version, '1.6.0');
    expect(File(pendingPath(fixture.target)).existsSync(), false);
  });
}
