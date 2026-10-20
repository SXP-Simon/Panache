import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'platform_files.dart';
import 'protocol.dart';
import 'process_identity.dart';

String installationKey(String target) => sha256
    .convert(utf8.encode(p.normalize(target)))
    .toString()
    .substring(0, 20);
String pendingPath(String target) => p.join(
  p.dirname(target),
  '.panache-pending-${installationKey(target)}.json',
);
String lockPath(String target) => p.join(
  p.dirname(target),
  '.panache-update-${installationKey(target)}.lock',
);

class InstallationLock {
  InstallationLock(String target)
    : file = File(lockPath(target)).openSync(mode: FileMode.append) {
    try {
      file.lockSync(FileLock.exclusive);
    } catch (_) {
      file.closeSync();
      reject('update_in_progress');
    }
  }
  final RandomAccessFile file;
  void close() {
    file.unlockSync();
    file.closeSync();
  }
}

Map<String, Object?> activeFor(InstallInfo info) => {
  'schema': protocolVersion,
  'product': product,
  'version': info.version,
  'build_number': info.build,
  'runtime': 'versions/${info.runtimeId}',
};

String windowsRuntime(String root, Map<String, dynamic> pointer) {
  final version = requireString(pointer, 'version'),
      relative = requireString(pointer, 'runtime');
  final build = pointer['build_number'];
  if (pointer['schema'] != protocolVersion ||
      pointer['product'] != product ||
      !validVersion(version) ||
      build is! int ||
      build < 1 ||
      relative != 'versions/$version-$build') {
    reject('invalid_active_version');
  }
  final runtime = p.join(root, 'versions', '$version-$build');
  if (!p.equals(Directory(runtime).resolveSymbolicLinksSync(), runtime)) {
    reject('invalid_active_version');
  }
  final info = InstallInfo.read(runtime, 'windows-x64');
  if (info.version != version ||
      info.build != build ||
      !File(p.join(runtime, info.executable)).existsSync()) {
    reject('invalid_active_version');
  }
  return runtime;
}

InstallInfo currentInstall(UpdatePlan plan) => plan.platform == 'windows-x64'
    ? InstallInfo.read(
        windowsRuntime(
          plan.target,
          readJson(p.join(plan.target, 'active.json')),
        ),
        plan.platform,
      )
    : InstallInfo.read(plan.target, plan.platform);

Future<void> verifyMacBundle(String target, {String? quarantineFrom}) async {
  if (!Platform.isMacOS) return;
  final signature = await Process.run('/usr/bin/codesign', [
    '--verify',
    '--deep',
    '--strict',
    target,
  ]);
  if (signature.exitCode != 0) reject('invalid_bundle_signature');
  final bundle = await Process.run('/usr/libexec/PlistBuddy', [
    '-c',
    'Print :CFBundleIdentifier',
    p.join(target, 'Contents', 'Info.plist'),
  ]);
  if (bundle.exitCode != 0 ||
      (bundle.stdout as String).trim() != 'io.github.sxpsimon.handwriting') {
    reject('invalid_bundle_identity');
  }
  if (quarantineFrom != null) {
    final quarantine = await Process.run('/usr/bin/xattr', [
      '-p',
      'com.apple.quarantine',
      quarantineFrom,
    ]);
    if (quarantine.exitCode == 0 &&
        (quarantine.stdout as String).trim().isNotEmpty) {
      final propagated = await Process.run('/usr/bin/xattr', [
        '-w',
        'com.apple.quarantine',
        (quarantine.stdout as String).trim(),
        target,
      ]);
      if (propagated.exitCode != 0) reject('quarantine_propagation_failed');
      final trust = await Process.run('/usr/sbin/spctl', [
        '--assess',
        '--type',
        'execute',
        target,
      ]);
      if (trust.exitCode != 0) reject('system_trust_required');
    }
  }
}

Future<Process> startApplication(
  String root,
  String platform, {
  String? transaction,
  String? token,
  String? failure,
}) async {
  final runtime = platform == 'windows-x64'
      ? windowsRuntime(root, readJson(p.join(root, 'active.json')))
      : root;
  final environment = <String, String>{
    'PANACHE_UPDATE_TRANSACTION': transaction ?? '',
    'PANACHE_UPDATE_TOKEN': token ?? '',
    'PANACHE_UPDATE_FAILURE': failure ?? '',
  };
  final process = await Process.start(
    p.join(runtime, executableFor(platform)),
    const [],
    workingDirectory: runtime,
    environment: environment,
  );
  unawaitedDrain(process.stdout);
  unawaitedDrain(process.stderr);
  return process;
}

void unawaitedDrain(Stream<List<int>> stream) {
  stream.drain<void>().ignore();
}

Future<void> launchWindows(String root) async {
  InstallInfo.read(root, 'windows-x64');
  final lock = InstallationLock(root);
  var recovered = false;
  try {
    if (File(pendingPath(root)).existsSync()) {
      requireUnprivilegedProcess();
      final pending = readJson(pendingPath(root));
      final directory = requireString(pending, 'transaction');
      final token = requireString(pending, 'token');
      final plan = UpdatePlan.read(directory, token);
      if (!p.equals(plan.target, root)) reject('invalid_journal');
      await stopRecordedProcesses(directory, plan);
      final good = readJson(p.join(root, 'last-good.json'));
      windowsRuntime(root, good);
      atomicFile(p.join(root, 'active.json'), good);
      File(pendingPath(root)).deleteSync();
      final bad = p.join(root, 'versions', '${plan.version}-${plan.build}');
      try {
        if (p.equals(p.dirname(bad), p.join(root, 'versions')) &&
            Directory(bad).existsSync() &&
            !p.equals(windowsRuntime(root, good), bad) &&
            p.equals(Directory(bad).resolveSymbolicLinksSync(), bad)) {
          Directory(bad).deleteSync(recursive: true);
        }
      } catch (_) {
        /* Locked failed-version files do not block launching the restored app. */
      }
      recovered = true;
    }
    final runtime = windowsRuntime(root, readJson(p.join(root, 'active.json')));
    await Process.start(
      p.join(runtime, executableFor('windows-x64')),
      const [],
      workingDirectory: runtime,
      mode: ProcessStartMode.detached,
      environment: {
        'PANACHE_UPDATE_FAILURE': recovered ? 'interrupted' : '',
        'PANACHE_UPDATE_TRANSACTION': '',
        'PANACHE_UPDATE_TOKEN': '',
      },
    );
  } finally {
    lock.close();
  }
}

Future<void> stopRecordedProcesses(
  String directory,
  UpdatePlan plan, {
  bool tolerateMissingJournal = false,
}) async {
  Map<String, dynamic> journal;
  try {
    journal = readJson(p.join(directory, 'journal.json'));
  } catch (_) {
    if (!tolerateMissingJournal) rethrow;
    journal = {'token': plan.token, 'target': plan.target};
  }
  if (journal['token'] != plan.token || journal['target'] != plan.target) {
    reject('invalid_journal');
  }
  final raw = journal['new_process'];
  if (raw is Map<String, dynamic>) {
    final identity = ProcessIdentity.fromJson(raw);
    final runtime = plan.platform == 'windows-x64'
        ? p.join(plan.target, 'versions', '${plan.version}-${plan.build}')
        : plan.target;
    if (!p.equals(
      identity.executable,
      p.join(runtime, executableFor(plan.platform)),
    )) {
      reject('invalid_process');
    }
    await identity.stopExact();
  }
  final started = File(p.join(directory, 'started.json'));
  if (started.existsSync()) {
    final data = readJson(started.path);
    if (data['token'] != plan.token) reject('invalid_process');
    final child = data['sidecar'];
    if (child is Map<String, dynamic>) {
      final identity = ProcessIdentity.fromJson(child);
      final runtime = plan.platform == 'windows-x64'
          ? p.join(plan.target, 'versions', '${plan.version}-${plan.build}')
          : plan.target;
      final relative = plan.platform == 'macos-arm64'
          ? 'Contents/Resources/backend/handwriting-server'
          : 'backend/handwriting-server${Platform.isWindows ? '.exe' : ''}';
      if (!p.equals(identity.executable, p.join(runtime, relative))) {
        reject('invalid_process');
      }
      await identity.stopExact();
    }
  }
}
