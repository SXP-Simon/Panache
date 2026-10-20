import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'protocol.dart';

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
    final ids = Platform.isWindows
        ? _Windows.pids()
        : Platform.isMacOS
        ? _Mac.pids()
        : Platform.isLinux
        ? Directory('/proc')
              .listSync(followLinks: false)
              .map((entry) => int.tryParse(p.basename(entry.path)))
              .whereType<int>()
              .toList()
        : reject('unsupported_platform');
    final matches = <ProcessIdentity>[];
    for (final candidate in ids.where((value) => value > 0)) {
      try {
        final identity = capture(candidate);
        if (identity == null) continue;
        final same = Platform.isWindows
            ? p.normalize(identity.executable).toLowerCase() ==
                  wanted.toLowerCase()
            : p.equals(identity.executable, wanted);
        if (same && identity.matchesLive()) matches.add(identity);
      } on UpdaterFailure catch (error) {
        // System/protected processes can be inaccessible and are not app instances.
        // A process exiting during enumeration is equally unrelated to this result.
        if (!{
          'process_identity_denied',
          'process_identity_changed',
        }.contains(error.code)) {
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
      (Platform.isWindows
          ? p.normalize(executable).toLowerCase() ==
                p.normalize(other.executable).toLowerCase()
          : p.equals(executable, other.executable));

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
        if (!{
          'process_identity_denied',
          'process_identity_changed',
        }.contains(error.code)) {
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
        if (!{
          'process_identity_denied',
          'process_identity_changed',
        }.contains(error.code)) {
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

class _Windows {
  static final _library = DynamicLibrary.open('kernel32.dll');
  static final _open = _library
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  static final _close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  static final _error = _library
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _enumerate = _library
      .lookupFunction<
        Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Uint32>, int, Pointer<Uint32>)
      >('K32EnumProcesses');
  static final _times = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
        )
      >('GetProcessTimes');
  static final _path = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Utf16>, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Utf16>, Pointer<Uint32>)
      >('QueryFullProcessImageNameW');
  static final _terminate = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('TerminateProcess');
  static final _wait = _library
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');

  static Pointer<Void> _handle(int pid, int access) {
    final handle = _open(access, 0, pid);
    if (handle == nullptr) {
      final error = _error();
      if ({87, 1168}.contains(error)) return nullptr;
      if (error == 5 && !_listed(pid)) return nullptr;
      reject('process_identity_denied');
    }
    return handle;
  }

  static bool _listed(int pid) => pids().contains(pid);

  static List<int> pids() {
    for (var count = 1024; count <= 262144; count *= 2) {
      final processes = calloc<Uint32>(count), needed = calloc<Uint32>();
      try {
        if (_enumerate(processes, count * 4, needed) == 0) {
          reject('process_identity_denied');
        }
        if (needed.value < count * 4) {
          return processes.asTypedList(needed.value ~/ 4).toList();
        }
      } finally {
        calloc.free(processes);
        calloc.free(needed);
      }
    }
    reject('process_identity_denied');
  }

  static ProcessIdentity? _read(Pointer<Void> handle, int pid) {
    if (_wait(handle, 0) == 0) return null;
    final times = calloc<Uint32>(8), length = calloc<Uint32>();
    final path = calloc<Uint16>(32768).cast<Utf16>();
    try {
      length.value = 32768;
      if (_times(handle, times, times + 2, times + 4, times + 6) == 0 ||
          _path(handle, 0, path, length) == 0) {
        if (_wait(handle, 0) == 0) return null;
        reject('process_identity_denied');
      }
      final started = (BigInt.from(times[1]) << 32) | BigInt.from(times[0]);
      return ProcessIdentity(
        pid,
        p.normalize(path.toDartString(length: length.value)),
        'windows:$started',
      );
    } finally {
      calloc.free(times);
      calloc.free(length);
      calloc.free(path);
    }
  }

  static ProcessIdentity? capture(int pid) {
    final handle = _handle(pid, 0x1000 | 0x100000);
    if (handle == nullptr) return null;
    try {
      return _read(handle, pid);
    } finally {
      _close(handle);
    }
  }

  static Future<void> stop(ProcessIdentity identity, Duration timeout) async {
    Pointer<Void> handle;
    try {
      handle = _handle(identity.pid, 0x1000 | 0x100000 | 0x1);
    } on UpdaterFailure catch (error) {
      // Windows briefly denies opening a process after it has terminated but
      // before its PID leaves enumeration. Never turn that into a broad kill.
      if (error.code == 'process_identity_denied' &&
          await identity.waitGone(timeout: timeout)) {
        return;
      }
      rethrow;
    }
    if (handle == nullptr) return;
    try {
      if (!identity._same(_read(handle, identity.pid))) return;
      if (_terminate(handle, 1) == 0 && _wait(handle, 0) != 0) {
        reject('process_stop_failed');
      }
      final clock = Stopwatch()..start();
      while (_wait(handle, 0) != 0) {
        if (clock.elapsed >= timeout) reject('process_stop_failed');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _close(handle);
    }
  }
}

String? _linuxStart(int pid) {
  final text = File('/proc/$pid/stat').readAsStringSync();
  final boundary = text.lastIndexOf(') ');
  if (boundary < 0) reject('process_identity_denied');
  final fields = text.substring(boundary + 2).split(RegExp(r'\s+'));
  if (fields.length < 20 || !RegExp(r'^\d+$').hasMatch(fields[19])) {
    reject('process_identity_denied');
  }
  if (fields[0] == 'Z' || fields[0] == 'X') return null;
  return fields[19];
}

ProcessIdentity? _linuxCapture(int pid) {
  String? sampled;
  try {
    final start = _linuxStart(pid);
    sampled = start;
    if (start == null) return null;
    final executable = Link('/proc/$pid/exe').resolveSymbolicLinksSync();
    final after = _linuxStart(pid);
    if (after == null) return null;
    if (after != start) reject('process_identity_changed');
    final boot = File('/proc/sys/kernel/random/boot_id')
        .readAsStringSync()
        .trim();
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(boot)) {
      reject('process_identity_denied');
    }
    return ProcessIdentity(pid, executable, 'linux:$boot:$start');
  } on FileSystemException catch (error) {
    if ({2, 3}.contains(error.osError?.errorCode)) {
      // Linux drops /proc/PID/exe before the task directory disappears. A
      // zombie/dead stat is conclusive; an unreadable live executable is not.
      try {
        final after = _linuxStart(pid);
        if (after == null) return null;
        if (sampled != null && after != sampled) {
          reject('process_identity_changed');
        }
      } on FileSystemException catch (recheck) {
        if ({2, 3}.contains(recheck.osError?.errorCode)) return null;
      }
    }
    reject('process_identity_denied');
  }
}

Future<void> _linuxStop(ProcessIdentity identity, Duration timeout) async {
  final library = DynamicLibrary.process();
  // All supported Linux packages use x86_64. pidfds bind the signal target to
  // the kernel process object, closing the PID-reuse race after verification.
  if (Abi.current() != Abi.linuxX64) reject('unsupported_platform');
  final call = library
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, int, int, int, int)
      >('syscall');
  final close = library
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  final fd = call(434, identity.pid, 0, 0, 0);
  if (fd < 0) {
    if (!await identity._matchesForSignal(timeout)) return;
    reject('process_identity_denied');
  }
  try {
    if (!await identity._matchesForSignal(timeout)) return;
    if (call(424, fd, 15, 0, 0) < 0 &&
        await identity._matchesForSignal(timeout)) {
      reject('process_stop_failed');
    }
    if (await identity.waitGone(timeout: timeout)) return;
    if (call(424, fd, 9, 0, 0) < 0 &&
        await identity._matchesForSignal(timeout)) {
      reject('process_stop_failed');
    }
    if (!await identity.waitGone(timeout: const Duration(seconds: 2))) {
      reject('process_stop_failed');
    }
  } finally {
    close(fd);
  }
}

class _Mac {
  static final _library = DynamicLibrary.open('/usr/lib/libproc.dylib');
  static final _info = _library
      .lookupFunction<
        Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
        int Function(int, int, int, Pointer<Void>, int)
      >('proc_pidinfo');
  static final _path = _library
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('proc_pidpath');
  static final _errno = DynamicLibrary.process()
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );

  static List<int> pids() {
    final list = _library
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)
        >('proc_listallpids');
    for (var count = 1024; count <= 262144; count *= 2) {
      final buffer = calloc<Int32>(count);
      try {
        final length = list(buffer.cast(), count * 4);
        if (length < 0) reject('process_identity_denied');
        if (length < count) return buffer.asTypedList(length).toList();
      } finally {
        calloc.free(buffer);
      }
    }
    reject('process_identity_denied');
  }

  static String? _start(int pid, Pointer<Uint8> buffer) {
    final result = _info(pid, 3, 0, buffer.cast(), 136);
    if (result != 136) {
      if ({2, 3}.contains(_errno().value)) return null;
      reject('process_identity_denied');
    }
    // Public XNU proc_bsdinfo: 12 uint32s, 48 chars, six uint32s,
    // followed by the two uint64 creation-time values (offsets 120/128).
    final data = ByteData.sublistView(buffer.asTypedList(136));
    if (data.getUint32(12, Endian.host) != pid) {
      reject('process_identity_changed');
    }
    if (data.getUint32(4, Endian.host) == 5) return null;
    return 'macos:${data.getUint64(120, Endian.host)}:${data.getUint64(128, Endian.host)}';
  }

  static ProcessIdentity? capture(int pid) {
    final buffer = calloc<Uint8>(136), path = calloc<Uint8>(4096);
    try {
      final started = _start(pid, buffer);
      if (started == null) return null;
      if (_path(pid, path.cast(), 4096) < 1) {
        if (_start(pid, buffer) == null) return null;
        reject('process_identity_denied');
      }
      final executable = path.cast<Utf8>().toDartString();
      final after = _start(pid, buffer);
      if (after == null) return null;
      if (after != started) reject('process_identity_changed');
      return ProcessIdentity(pid, executable, started);
    } finally {
      calloc.free(buffer);
      calloc.free(path);
    }
  }
}
