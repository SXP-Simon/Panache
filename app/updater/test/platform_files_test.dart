import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:panache_updater/platform_files.dart';
import 'package:panache_updater/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('Win32 conversion preserves the ordinary protocol path and accepts spaces or Unicode', () {
    expect(
      windowsExtendedPath(r'C:\Users\测试 用户\request.json'),
      r'\\?\C:\Users\测试 用户\request.json',
    );
    expect(
      windowsExtendedPath('D:/Panache/data.json'),
      r'\\?\D:\Panache\data.json',
    );
  });
  for (final value in [
    r'\\server\share\request.json',
    r'\\?\C:\request.json',
    r'\\.\C:\request.json',
    r'C:relative.json',
    r'C:\outside\..\request.json',
    r'C:\request.json:stream',
    r'C:\CON',
    r'C:\bad.\file.json',
    r'C:\bad \file.json',
  ]) {
    test('Win32 conversion rejects non-local or ambiguous input $value', () {
      expect(
        () => windowsExtendedPath(value),
        throwsA(
          predicate(
            (e) => e is UpdaterFailure && e.code == 'invalid_native_path',
          ),
        ),
      );
    });
  }
  test('real Win32 atomic writes replace a file whose ordinary path exceeds MAX_PATH', () {
    if (!Platform.isWindows) return;
    final temporary = Directory.systemTemp.createTempSync(
      'panache-native-path-',
    );
    final root = Directory(temporary.resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    final deep = Directory(
      p.joinAll([
        root.path,
        ...List.generate(12, (i) => '中文 deep path segment $i'),
      ]),
    )..createSync(recursive: true);
    final path = p.join(deep.path, 'request.json');
    expect(path.length, greaterThan(300));
    atomicFile(path, {'generation': 1});
    expect(readJson(path), {'generation': 1});
    atomicFile(path, {'generation': 2});
    expect(readJson(path), {'generation': 2});
    expect(
      Directory(windowsExtendedPath(deep.path))
          .listSync()
          .map((entry) => p.basename(entry.path)),
      ['request.json'],
    );
  });
  test('real Win32 failures retain their OS error and leave the previous JSON intact', () {
    if (!Platform.isWindows) return;
    final root = Directory.systemTemp.createTempSync('panache-native-error-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = p.join(root.path, 'request.json');
    atomicFile(path, {'before': true});
    final attributes = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, int)
        >('SetFileAttributesW');
    final native = windowsExtendedPath(path).toNativeUtf16();
    try {
      expect(attributes(native, 1), 1);
      expect(
        () => atomicFile(path, {'after': true}),
        throwsA(
          predicate(
            (e) =>
                e is UpdaterFailure &&
                e.code == 'atomic_write_failed' &&
                e.osError == 5 &&
                e.toString().contains('osError: 5'),
          ),
        ),
      );
      expect(readJson(path), {'before': true});
    } finally {
      attributes(native, 128);
      calloc.free(native);
    }
  });
}
