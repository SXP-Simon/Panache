import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'protocol.dart';

void atomicFile(String path, Map<String, Object?> value) {
  final temporary = File('$path.${secureToken()}.tmp');
  final sourcePath = Platform.isWindows
      ? windowsExtendedPath(temporary.path)
      : temporary.path;
  final destinationPath = Platform.isWindows ? windowsExtendedPath(path) : path;
  temporary.writeAsStringSync(jsonEncode(value), flush: true);
  try {
    if (Platform.isWindows) {
      final move = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('MoveFileExW');
      final source = sourcePath.toNativeUtf16(),
          destination = destinationPath.toNativeUtf16();
      try {
        final lastError = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
        final clock = Stopwatch()..start();
        while (move(source, destination, 0x1 | 0x8) == 0) {
          final error = lastError();
          if (!{5, 32, 33}.contains(error) ||
              clock.elapsed >= const Duration(seconds: 2)) {
            reject('atomic_write_failed', osError: error);
          }
          sleep(const Duration(milliseconds: 25));
        }
      } finally {
        calloc.free(source);
        calloc.free(destination);
      }
    } else {
      temporary.renameSync(path);
      syncDirectory(p.dirname(path));
    }
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

void syncDirectory(String directory) {
  if (Platform.isWindows) return;
  final libc = DynamicLibrary.process();
  final open = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  final sync = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'fsync',
  );
  final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'close',
  );
  final name = directory.toNativeUtf8();
  final fd = open(name, 0);
  calloc.free(name);
  if (fd < 0) reject('directory_sync_failed');
  try {
    if (sync(fd) != 0) reject('directory_sync_failed');
  } finally {
    close(fd);
  }
}

void exchangeDirectories(String left, String right) {
  if (p.dirname(left) != p.dirname(right)) reject('different_volume');
  final a = left.toNativeUtf8(), b = right.toNativeUtf8();
  try {
    if (Platform.isLinux) {
      final exchange = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
            int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
          >('renameat2');
      if (exchange(-100, a, -100, b, 2) != 0) {
        reject('atomic_exchange_unavailable');
      }
    } else if (Platform.isMacOS) {
      final exchange = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('renamex_np');
      if (exchange(a, b, 2) != 0) reject('atomic_exchange_unavailable');
    } else {
      reject('atomic_exchange_unavailable');
    }
  } finally {
    calloc.free(a);
    calloc.free(b);
  }
  syncDirectory(p.dirname(left));
}

void setMode(String path, int mode) {
  if (Platform.isWindows) return;
  final chmod = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  final name = path.toNativeUtf8();
  try {
    if (chmod(name, mode & 0x1ff) != 0) reject('permission_denied');
  } finally {
    calloc.free(name);
  }
}

void verifyWritableInstallation(String target, String platform) {
  if (platform.startsWith('macos') && Platform.isMacOS) {
    if ((Platform.environment['APP_SANDBOX_CONTAINER_ID'] ?? '').isNotEmpty) {
      reject('sandbox_installation');
    }
    final entitlements = Process.runSync('/usr/bin/codesign', [
      '-d',
      '--entitlements',
      ':-',
      target,
    ]);
    if (entitlements.exitCode != 0) reject('invalid_bundle_signature');
    if (RegExp(r'<key>com\.apple\.security\.app-sandbox</key>\s*<true\s*/>')
        .hasMatch('${entitlements.stdout}')) {
      reject('sandbox_installation');
    }
  }
  final canonical = Directory(target).resolveSymbolicLinksSync();
  if (!p.equals(canonical, p.normalize(target)) ||
      p.dirname(target) == target) {
    reject('invalid_target');
  }
  if (platform.startsWith('linux') &&
      [
        '/usr',
        '/opt',
        '/snap',
        '/app',
        '/var/lib',
      ].any((root) => p.equals(target, root) || p.isWithin(root, target))) {
    reject('managed_installation');
  }
  if (platform.startsWith('macos') &&
      (target.contains('/AppTranslocation/') ||
          target.startsWith('/Volumes/'))) {
    reject('managed_installation');
  }
  if (platform.startsWith('windows')) {
    for (final name in ['WINDIR', 'ProgramFiles', 'ProgramFiles(x86)']) {
      final root = Platform.environment[name];
      if (root != null &&
          (p.equals(root, target) || p.isWithin(root, target))) {
        reject('managed_installation');
      }
    }
  }
  final probe = Directory(
    p.join(p.dirname(target), '.panache-probe-${secureToken()}'),
  )..createSync();
  try {
    File(p.join(probe.path, 'probe')).writeAsStringSync('Panache', flush: true);
    if (!Platform.isWindows) {
      final other = Directory('${probe.path}-other')..createSync();
      try {
        exchangeDirectories(probe.path, other.path);
        exchangeDirectories(probe.path, other.path);
      } finally {
        other.deleteSync(recursive: true);
      }
    }
  } finally {
    probe.deleteSync(recursive: true);
  }
}

void requireUnprivilegedProcess() {
  if (!Platform.isWindows) {
    final effectiveUser = DynamicLibrary.process()
        .lookupFunction<Uint32 Function(), int Function()>('geteuid');
    if (effectiveUser() == 0) reject('elevated_process');
    return;
  }
  final kernel = DynamicLibrary.open('kernel32.dll'),
      security = DynamicLibrary.open('advapi32.dll');
  final current = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  final open = security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('OpenProcessToken');
  final info = security
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetTokenInformation');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final token = calloc<Pointer<Void>>(),
      elevation = calloc<Uint32>(),
      length = calloc<Uint32>();
  try {
    if (open(current(), 8, token) == 0 ||
        info(token.value, 20, elevation.cast(), 4, length) == 0) {
      reject('process_privilege_unknown');
    }
    if (elevation.value != 0) reject('elevated_process');
  } finally {
    if (token.value != nullptr) close(token.value);
    calloc.free(token);
    calloc.free(elevation);
    calloc.free(length);
  }
}
