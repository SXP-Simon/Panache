import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'installation.dart';
import 'platform_files.dart';
import 'protocol.dart';
import 'process_identity.dart';
import 'safe_archive.dart';

class UpdateTransaction {
  UpdateTransaction(
    this.directory,
    this.plan, {
    this.healthTimeout = const Duration(seconds: 60),
    this.onPhase,
  });
  final String directory;
  final UpdatePlan plan;
  final Duration healthTimeout;
  final void Function(String)? onPhase;
  late final String stage = p.join(
    p.dirname(plan.target),
    '.panache-stage-${plan.token}${plan.platform == 'macos-arm64' ? '.app' : ''}',
  );
  late final String unpack = p.join(
    p.dirname(plan.target),
    '.panache-unpack-${plan.token}',
  );
  String? newRuntime;
  Map<String, dynamic>? previous;
  InstallationLock? _lock;
  bool switched = false;
  bool parentConfirmedExited = false;
  bool get ownsInstallation => _lock != null;
  Process? _newApp;
  ProcessIdentity? _newIdentity, _oldSidecar;
  bool _newAppExited = false;

  void record(String phase, {String? reason}) {
    atomicFile(p.join(directory, 'journal.json'), {
      'schema': protocolVersion,
      'product': product,
      'token': plan.token,
      'phase': phase,
      'target': plan.target,
      'stage': stage,
      'new_runtime': newRuntime,
      'previous': previous,
      'version': plan.version,
      'reason': reason,
      'new_process': _newIdentity?.toJson(),
    });
    File(p.join(directory, 'update.log')).writeAsStringSync(
      '${DateTime.now().toUtc().toIso8601String()} $phase ${reason ?? ''}\n',
      mode: FileMode.append,
      flush: true,
    );
    onPhase?.call(phase);
  }

  Future<void> prepare() async {
    verifyWritableInstallation(plan.target, plan.platform);
    final installed = currentInstall(plan);
    if (installed.version != plan.currentVersion ||
        (installed.version == plan.version && installed.build >= plan.build)) {
      reject('installation_changed');
    }
    final runtime = plan.platform == 'windows-x64'
        ? windowsRuntime(
            plan.target,
            readJson(p.join(plan.target, 'active.json')),
          )
        : plan.target;
    if (!p.equals(
          plan.parent.executable,
          p.join(runtime, executableFor(plan.platform)),
        ) ||
        !plan.parent.matchesLive()) {
      reject('invalid_parent');
    }
    if (await hashFile(p.join(runtime, executableFor(plan.platform))) !=
        plan.currentSha256) {
      reject('installation_changed');
    }
    if (plan.sidecarPid != null) {
      _oldSidecar = ProcessIdentity.capture(plan.sidecarPid!);
      final relative = plan.platform == 'macos-arm64'
          ? 'Contents/Resources/backend/handwriting-server'
          : 'backend/handwriting-server${Platform.isWindows ? '.exe' : ''}';
      if (_oldSidecar == null ||
          !p.equals(_oldSidecar!.executable, p.join(runtime, relative))) {
        reject('invalid_process');
      }
    }
    _lock = InstallationLock(plan.target);
    if (ProcessIdentity.matchingExecutable(plan.parent.executable)
        .any((instance) => instance.pid != plan.parent.pid)) {
      reject('another_instance_running');
    }
    if (File(pendingPath(plan.target)).existsSync()) {
      reject('recovery_required');
    }
    record('preparing');
    final suffix = plan.platform == 'linux-x64'
        ? 'linux-x64.tar.gz'
        : '${plan.platform}.zip';
    if (p.basename(plan.archive) != 'Flutter-Panache-${plan.version}-$suffix' ||
        FileSystemEntity.typeSync(plan.archive, followLinks: false) !=
            FileSystemEntityType.file) {
      reject('invalid_source');
    }
    final snapshot = p.join(
      directory,
      'package.${plan.platform == 'linux-x64' ? 'tar.gz' : 'zip'}',
    );
    if (File(plan.archive).lengthSync() > 2 * 1024 * 1024 * 1024) {
      reject('archive_too_large');
    }
    await File(plan.archive).copy(snapshot);
    if (await hashFile(snapshot) != plan.sha256) reject('package_changed');
    final payload = await extractPackage(snapshot, unpack, plan.platform);
    final next = InstallInfo.read(payload, plan.platform);
    if (next.version != plan.version || next.build != plan.build) {
      reject('package_version_mismatch');
    }
    if (plan.platform == 'windows-x64') {
      previous = readJson(p.join(plan.target, 'active.json'));
      final candidate = windowsRuntime(payload, activeFor(next));
      final versions = Directory(p.join(plan.target, 'versions'));
      if (FileSystemEntity.typeSync(versions.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        reject('invalid_target');
      }
      newRuntime = p.join(versions.path, next.runtimeId);
      if (FileSystemEntity.typeSync(newRuntime!, followLinks: false) !=
          FileSystemEntityType.notFound) {
        reject('version_already_staged');
      }
      await Directory(candidate).rename(newRuntime!);
    } else {
      await Directory(payload).rename(stage);
      if (!File(p.join(stage, executableFor(plan.platform))).existsSync()) {
        reject('missing_executable');
      }
      if (plan.platform == 'macos-arm64') {
        await verifyMacBundle(stage, quarantineFrom: plan.target);
        await verifyMacBundle(stage, quarantineFrom: plan.archive);
      }
    }
    if (await hashFile(snapshot) != plan.sha256) reject('package_changed');
    record('prepared');
  }

  Future<void> applyAfterExit() async {
    if (!await plan.parent.waitGone()) reject('parent_still_running');
    parentConfirmedExited = true;
    if (_oldSidecar != null && !await _oldSidecar!.waitGone()) {
      await _oldSidecar!.stopExact();
      reject('backend_still_running');
    }
    record('applying');
    final installed = currentInstall(plan);
    if (installed.version != plan.currentVersion) {
      reject('installation_changed');
    }
    atomicFile(pendingPath(plan.target), {
      'schema': protocolVersion,
      'product': product,
      'token': plan.token,
      'transaction': directory,
    });
    if (plan.platform == 'windows-x64') {
      atomicFile(p.join(plan.target, 'last-good.json'), previous!);
      atomicFile(
        p.join(plan.target, 'active.json'),
        activeFor(InstallInfo.read(newRuntime!, plan.platform)),
      );
    } else {
      exchangeDirectories(plan.target, stage);
    }
    switched = true;
    record('switched');
    _newApp = await startApplication(
      plan.target,
      plan.platform,
      transaction: directory,
      token: plan.token,
    );
    _newIdentity = ProcessIdentity.capture(_newApp!.pid);
    unawaited(
      _newApp!.exitCode.then((_) {
        _newAppExited = true;
      }),
    );
    record('awaiting_health');
    final deadline = DateTime.now().add(healthTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_newAppExited) reject('restart_failed');
      final ack = p.join(directory, 'healthy.json');
      if (File(ack).existsSync()) {
        final data = readJson(ack);
        if (data['schema'] == protocolVersion &&
            data['product'] == product &&
            data['token'] == plan.token &&
            data['version'] == plan.version &&
            data['build_number'] == plan.build &&
            data['ready'] == true &&
            data['gui_pid'] == _newApp!.pid) {
          record('committed');
          File(pendingPath(plan.target)).deleteSync();
          syncDirectory(p.dirname(plan.target));
          _lock?.close();
          _lock = null;
          cleanupAfterCommit();
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    reject('health_timeout');
  }

  void cleanupAfterCommit() {
    if (plan.platform == 'windows-x64') {
      final keep = {
        '${plan.version}-${plan.build}',
        if (previous != null) p.basename(requireString(previous!, 'runtime')),
      };
      for (final entry in Directory(
        p.join(plan.target, 'versions'),
      ).listSync(followLinks: false)) {
        if (entry is! Directory || keep.contains(p.basename(entry.path))) {
          continue;
        }
        try {
          final info = InstallInfo.read(entry.path, plan.platform);
          if (p.basename(entry.path) == info.runtimeId) {
            deleteOwned(entry.path, p.join(plan.target, 'versions'));
          }
        } catch (_) {
          /* Unknown files or a still-running previous version are retained. */
        }
      }
    }
    for (final path in [unpack, if (plan.platform != 'windows-x64') stage]) {
      try {
        if (Directory(path).existsSync()) {
          deleteOwned(path, p.dirname(plan.target));
        }
      } catch (_) {
        /* A cache cleanup failure cannot roll back an already healthy app. */
      }
    }
  }

  Future<void> rollback(String reason) async {
    try {
      record('rolling_back', reason: reason);
    } catch (_) {
      /* Recovery must continue if the journal disk is full. */
    }
    if (!_newAppExited) {
      if (_newIdentity != null) {
        await _newIdentity!.stopExact();
      } else if (_newApp != null) {
        // The owned Process object retains its OS handle; it cannot target a reused PID.
        _newApp!.kill();
        try {
          await _newApp!.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          _newApp!.kill(ProcessSignal.sigkill);
          await _newApp!.exitCode.timeout(const Duration(seconds: 5));
        }
      }
    }
    await stopRecordedProcesses(directory, plan, tolerateMissingJournal: true);
    switched = isApplied();
    if (switched) {
      if (plan.platform == 'windows-x64') {
        windowsRuntime(plan.target, previous!);
        atomicFile(p.join(plan.target, 'active.json'), previous!);
      } else {
        final backup = InstallInfo.read(stage, plan.platform);
        if (backup.version != plan.currentVersion) reject('invalid_backup');
        exchangeDirectories(plan.target, stage);
      }
      switched = false;
    }
    if (File(pendingPath(plan.target)).existsSync()) {
      File(pendingPath(plan.target)).deleteSync();
    }
    try {
      record('rolled_back', reason: reason);
    } catch (_) {
      /* The restored app can still start when diagnostics cannot be saved. */
    }
    if (plan.platform == 'windows-x64') {
      final runtime = p.join(
        plan.target,
        'versions',
        '${plan.version}-${plan.build}',
      );
      try {
        if (Directory(runtime).existsSync()) {
          deleteOwned(runtime, p.join(plan.target, 'versions'));
        }
      } catch (_) {
        /* A locked cache must not prevent restarting the restored application. */
      }
    }
    _lock?.close();
    _lock = null;
    if (_oldSidecar != null &&
        !await _oldSidecar!.waitGone(timeout: const Duration(seconds: 5))) {
      await _oldSidecar!.stopExact();
    }
    await startApplication(plan.target, plan.platform, failure: reason);
  }

  Future<void> abort() async {
    if (_lock == null) return;
    switched = isApplied();
    if (switched) {
      await rollback('cancelled');
      return;
    }
    try {
      record('cancelled');
    } catch (_) {
      /* Cleanup and releasing the installation lock must still happen. */
    }
    if (newRuntime != null && Directory(newRuntime!).existsSync()) {
      deleteOwned(newRuntime!, p.join(plan.target, 'versions'));
    }
    for (final path in [stage, unpack]) {
      if (Directory(path).existsSync()) {
        deleteOwned(path, p.dirname(plan.target));
      }
    }
    _lock?.close();
    _lock = null;
  }

  bool isApplied() {
    try {
      final info = currentInstall(plan);
      return info.version == plan.version && info.build == plan.build;
    } catch (_) {
      return false;
    }
  }

  void deleteOwned(String path, String parent) {
    if (!p.equals(p.dirname(path), parent) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(
          Directory(path).resolveSymbolicLinksSync(),
          p.normalize(path),
        )) {
      reject('invalid_cleanup');
    }
    Directory(path).deleteSync(recursive: true);
  }

  void prepareRecovery() {
    _lock = InstallationLock(plan.target);
    final journal = readJson(p.join(directory, 'journal.json'));
    if (journal['token'] != plan.token ||
        journal['target'] != plan.target ||
        journal['stage'] != stage) {
      reject('invalid_journal');
    }
  }

  void cancelRecovery() {
    _lock?.close();
    _lock = null;
  }

  Future<void> recover() async {
    _lock ??= InstallationLock(plan.target);
    final journal = readJson(p.join(directory, 'journal.json'));
    if (journal['token'] != plan.token ||
        journal['target'] != plan.target ||
        journal['stage'] != stage) {
      reject('invalid_journal');
    }
    final old = journal['previous'];
    if (old is Map<String, dynamic>) previous = old;
    final raw = journal['new_process'];
    if (raw is Map<String, dynamic>) {
      _newIdentity = ProcessIdentity.fromJson(raw);
    }
    switched = isApplied();
    if (!{'committed', 'rolled_back', 'cancelled'}.contains(journal['phase'])) {
      await rollback('interrupted');
    } else {
      _lock?.close();
      _lock = null;
    }
  }
}
