part of '../process_identity.dart';

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
