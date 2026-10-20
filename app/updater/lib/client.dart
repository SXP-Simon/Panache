import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'installation.dart';
import 'platform_files.dart';
import 'process_identity.dart';
import 'protocol.dart';

class RunningInstallation {
  RunningInstallation(this.root, this.runtime, this.info);
  final String root, runtime;
  final InstallInfo info;
  static RunningInstallation detect() {
    final executable = File(Platform.resolvedExecutable)
        .resolveSymbolicLinksSync();
    final platform = Platform.isWindows
        ? 'windows-x64'
        : Platform.isMacOS
        ? 'macos-arm64'
        : 'linux-x64';
    final runtime = Platform.isMacOS
        ? p.dirname(p.dirname(p.dirname(executable)))
        : p.dirname(executable);
    final info = InstallInfo.read(runtime, platform);
    if (!p.equals(executable, p.join(runtime, info.executable))) {
      reject('invalid_target');
    }
    final root = Platform.isWindows ? p.dirname(p.dirname(runtime)) : runtime;
    if (Platform.isWindows &&
        (!p.equals(p.basename(p.dirname(runtime)), 'versions') ||
            !p.equals(
              windowsRuntime(root, readJson(p.join(root, 'active.json'))),
              runtime,
            ))) {
      reject('invalid_target');
    }
    return RunningInstallation(root, runtime, info);
  }

  String get helper => p.join(
    runtime,
    Platform.isMacOS
        ? 'Contents/Resources/backend/panache-updater'
        : 'backend/panache-updater${Platform.isWindows ? '.exe' : ''}',
  );
}

class PreparedDesktopUpdate {
  PreparedDesktopUpdate(this.process, this.token, this.onAbort);
  final void Function() onAbort;
  final Process process;
  final String token;
  bool armed = false, aborted = false;
  void arm() {
    if (aborted) reject('cancelled');
    process.stdin.writeln('ARM $token');
    armed = true;
  }

  Future<void> abort() async {
    if (aborted) return;
    aborted = true;
    onAbort();
    try {
      process.stdin.writeln('ABORT $token');
      await process.stdin.flush();
      await process.stdin.close();
    } catch (_) {
      /* Already closed helper: no installation is armed. */
    }
  }
  // Deliberately keep stdin open after ARM. Only parent-process termination
  // produces EOF; cancelling a window close cannot start installation.
}

Future<PreparedDesktopUpdate> launchPreparedHelper(
  String source,
  String directory,
  String token, {
  bool recovery = false,
  void Function(PreparedDesktopUpdate)? onStarted,
}) async {
  validateTransactionDirectory(directory, token);
  final helper = p.join(
    directory,
    'panache-updater${Platform.isWindows ? '.exe' : ''}',
  );
  if (!File(helper).existsSync()) {
    if (recovery) reject('missing_recovery_helper');
    await File(source).copy(helper);
    setMode(helper, 0x1c0);
    final hash = await hashFile(source);
    if (hash != await hashFile(helper)) reject('helper_changed');
    atomicFile(p.join(directory, 'helper.json'), {
      'schema': protocolVersion,
      'product': product,
      'token': token,
      'sha256': hash,
    });
  } else {
    final metadata = readJson(p.join(directory, 'helper.json'));
    if (metadata['schema'] != protocolVersion ||
        metadata['product'] != product ||
        metadata['token'] != token ||
        metadata['sha256'] != await hashFile(helper)) {
      reject('helper_changed');
    }
  }
  final process = await Process.start(
    helper,
    [recovery ? '--recover' : '--prepare', directory, token],
    workingDirectory: directory,
    mode: ProcessStartMode.detachedWithStdio,
  );
  final ready = Completer<void>();
  final session = PreparedDesktopUpdate(process, token, () {
    if (!ready.isCompleted) {
      ready.completeError(const UpdaterFailure('cancelled'));
    }
  });
  onStarted?.call(session);
  process.stderr
      .transform(utf8.decoder)
      .listen(
        (text) {
          if (text.contains('PANACHE_UPDATE_ERROR') && !ready.isCompleted) {
            ready.completeError(const UpdaterFailure('prepare_failed'));
          }
        },
        onError: (Object error) {
          if (!ready.isCompleted) ready.completeError(error);
        },
      );
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line == 'PANACHE_UPDATE_READY $token' && !ready.isCompleted) {
            ready.complete();
          }
        },
        onDone: () {
          if (!ready.isCompleted) {
            ready.completeError(const UpdaterFailure('helper_exited'));
          }
        },
        onError: (Object error) {
          if (!ready.isCompleted) ready.completeError(error);
        },
      );
  try {
    await ready.future.timeout(const Duration(minutes: 5));
    return session;
  } catch (_) {
    await session.abort();
    rethrow;
  }
}

Future<PreparedDesktopUpdate> prepareDesktopUpdate({
  required String supportDirectory,
  required String archive,
  required String sha256,
  required String version,
  required int build,
  int? sidecarPid,
  void Function(PreparedDesktopUpdate)? onStarted,
}) async {
  requireUnprivilegedProcess();
  final running = RunningInstallation.detect();
  final updates = Directory(p.join(supportDirectory, 'updates'))
    ..createSync(recursive: true);
  if (!p.equals(
    updates.resolveSymbolicLinksSync(),
    p.normalize(updates.path),
  )) {
    reject('invalid_transaction');
  }
  atomicFile(p.join(updates.path, 'updater-root.json'), {
    'schema': protocolVersion,
    'product': product,
  });
  final token = secureToken();
  final directory = Directory(p.join(updates.path, 'transactions', token))
    ..createSync(recursive: true);
  setMode(directory.path, 0x1c0);
  final plan = UpdatePlan(
    token: token,
    target: running.root,
    archive: archive,
    sha256: sha256,
    platform: running.info.platform,
    version: version,
    build: build,
    currentVersion: running.info.version,
    currentSha256: await hashFile(Platform.resolvedExecutable),
    sidecarPid: sidecarPid,
    parent: ProcessIdentity.capture(pid) ?? reject('invalid_parent'),
  );
  atomicFile(p.join(directory.path, 'request.json'), plan.toJson());
  return launchPreparedHelper(
    running.helper,
    directory.path,
    token,
    onStarted: onStarted,
  );
}

class DesktopUpdateStartup {
  DesktopUpdateStartup(this.running, this.directory, this.plan);
  final RunningInstallation running;
  final String directory;
  final UpdatePlan plan;
  static DesktopUpdateStartup? read(String supportDirectory) {
    try {
      final directory =
          Platform.environment['PANACHE_UPDATE_TRANSACTION'] ?? '';
      final token = Platform.environment['PANACHE_UPDATE_TOKEN'] ?? '';
      if (!validToken(token) ||
          !p.equals(
            directory,
            p.join(supportDirectory, 'updates', 'transactions', token),
          )) {
        return null;
      }
      final running = RunningInstallation.detect();
      final plan = UpdatePlan.read(directory, token);
      if (!p.equals(plan.target, running.root) ||
          plan.version != running.info.version ||
          plan.build != running.info.build) {
        return null;
      }
      return DesktopUpdateStartup(running, directory, plan);
    } catch (_) {
      return null;
    }
  }

  void recordStarted({int? sidecarPid}) {
    final sidecar = sidecarPid == null
        ? null
        : ProcessIdentity.capture(sidecarPid);
    atomicFile(p.join(directory, 'started.json'), {
      'schema': protocolVersion,
      'product': product,
      'token': plan.token,
      'gui_pid': pid,
      'sidecar': sidecar?.toJson(),
    });
  }

  void acknowledge(String backendVersion) {
    if (backendVersion.replaceFirst(RegExp(r'^v'), '') != plan.version) {
      reject('backend_version_mismatch');
    }
    atomicFile(p.join(directory, 'healthy.json'), {
      'schema': protocolVersion,
      'product': product,
      'token': plan.token,
      'version': plan.version,
      'build_number': plan.build,
      'gui_pid': pid,
      'ready': true,
    });
  }
}

Future<PreparedDesktopUpdate?> recoverInterruptedUpdate(
  String supportDirectory,
) async {
  RunningInstallation running;
  try {
    running = RunningInstallation.detect();
  } catch (_) {
    return null;
  }
  final pending = File(pendingPath(running.root));
  if (!pending.existsSync()) return null;
  final value = readJson(pending.path);
  final token = requireString(value, 'token');
  final directory = requireString(value, 'transaction');
  if (!p.equals(
    directory,
    p.join(supportDirectory, 'updates', 'transactions', token),
  )) {
    reject('invalid_transaction');
  }
  final plan = UpdatePlan.read(directory, token);
  if (!p.equals(plan.target, running.root)) reject('invalid_target');
  return launchPreparedHelper(running.helper, directory, token, recovery: true);
}

bool supportsAutomaticDesktopUpdate() {
  try {
    requireUnprivilegedProcess();
    final running = RunningInstallation.detect();
    if (FileSystemEntity.typeSync(running.helper, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    verifyWritableInstallation(running.root, running.info.platform);
    return true;
  } catch (_) {
    return false;
  }
}
