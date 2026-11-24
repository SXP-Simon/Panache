import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'updater_failure.dart';

part 'process_identity/linux.dart';
part 'process_identity/macos.dart';
part 'process_identity/windows.dart';

/// Persistent identity includes creation time, never just a reusable PID.
class ProcessIdentity {
  const ProcessIdentity(this.pid, this.executable, this.started);
  final int pid;
  final String executable, started;

  static ProcessIdentity? capture(int pid) {
    if (pid < 1 || pid > 0x7fffffff) reject('invalid_process_identity');
    if (Platform.isWindows) return _Windows.capture(pid);
    if (Platform.isLinux) return _linuxCapture(pid);
    if (Platform.isMacOS) return _Mac.capture(pid);
    reject('unsupported_platform');
  }

  static List<ProcessIdentity> matchingExecutable(String executable) {
    final wanted = p.normalize(executable);
    final matches = <ProcessIdentity>[];
    for (final candidate in _systemPids().where((value) => value > 0)) {
      try {
        final identity = capture(candidate);
        if (identity == null) continue;
        if (_sameExecutable(identity.executable, wanted) &&
            identity.matchesLive()) {
          matches.add(identity);
        }
      } on UpdaterFailure catch (error) {
        // System/protected processes can be inaccessible and are not app instances.
        // A process exiting during enumeration is equally unrelated to this result.
        if (!_isUncertainIdentity(error)) {
          rethrow;
        }
      }
    }
    return matches;
  }

  factory ProcessIdentity.fromJson(Map<String, dynamic> value) {
    final pid = value['pid'], executable = value['executable'];
    final started = value['started'];
    if (value.length != 3 ||
        pid is! int ||
        pid < 1 ||
        pid > 0x7fffffff ||
        executable is! String ||
        !p.isAbsolute(executable) ||
        executable.contains('\x00') ||
        executable.length > 32768 ||
        started is! String ||
        started.length > 200 ||
        !RegExp(
          r'^(windows:[0-9]+|linux:[a-f0-9-]{36}:[0-9]+|macos:[0-9]+:[0-9]+)$',
        ).hasMatch(started)) {
      reject('invalid_process_identity');
    }
    return ProcessIdentity(pid, executable, started);
  }

  Map<String, Object> toJson() => {
    'pid': pid,
    'executable': executable,
    'started': started,
  };

  bool _same(ProcessIdentity? other) =>
      other != null &&
      pid == other.pid &&
      started == other.started &&
      _sameExecutable(executable, other.executable);

  bool matchesLive() => _same(capture(pid));

  Future<bool> waitGone({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final clock = Stopwatch()..start();
    while (true) {
      try {
        if (!matchesLive()) return true;
      } on UpdaterFailure catch (error) {
        // An access error while a process exits is not evidence it has gone.
        if (!_isUncertainIdentity(error)) {
          rethrow;
        }
      }
      if (clock.elapsed >= timeout) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<bool> _matchesForSignal(Duration timeout) async {
    final clock = Stopwatch()..start();
    while (true) {
      try {
        return matchesLive();
      } on UpdaterFailure catch (error) {
        if (!_isUncertainIdentity(error)) {
          rethrow;
        }
        // An unreadable snapshot is unknown, never gone and never a signal
        // target. Re-read until one coherent identity can be compared.
        if (clock.elapsed >= timeout) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> stopExact({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (pid == currentPid) reject('process_self_stop');
    if (Platform.isWindows) {
      await _Windows.stop(this, timeout);
      return;
    }
    if (!await _matchesForSignal(timeout)) return;
    if (Platform.isLinux) {
      await _linuxStop(this, timeout);
      return;
    }
    if (!Platform.isMacOS) reject('unsupported_platform');
    // Darwin exposes PID-based signals. Recheck creation time before each one;
    // never fall back to a name/group-wide kill if identity cannot be read.
    if (!await _matchesForSignal(timeout)) return;
    Process.killPid(pid, ProcessSignal.sigterm);
    if (await waitGone(timeout: timeout)) return;
    if (!await _matchesForSignal(timeout)) return;
    Process.killPid(pid, ProcessSignal.sigkill);
    if (!await waitGone(timeout: const Duration(seconds: 2))) {
      reject('process_stop_failed');
    }
  }
}

int get currentPid => pid;

List<int> _systemPids() {
  if (Platform.isWindows) return _Windows.pids();
  if (Platform.isMacOS) return _Mac.pids();
  if (Platform.isLinux) {
    return Directory('/proc')
        .listSync(followLinks: false)
        .map((entry) => int.tryParse(p.basename(entry.path)))
        .whereType<int>()
        .toList();
  }
  reject('unsupported_platform');
}

bool _sameExecutable(String first, String second) => Platform.isWindows
    ? p.normalize(first).toLowerCase() == p.normalize(second).toLowerCase()
    : p.equals(first, second);

bool _isUncertainIdentity(UpdaterFailure error) =>
    error.code == 'process_identity_denied' ||
    error.code == 'process_identity_changed';
