part of '../process_identity.dart';

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
