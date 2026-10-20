import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:panache_updater/safe_archive.dart';
import 'package:panache_updater/protocol.dart';
import 'package:test/test.dart';

ArchiveFile link(String name, String target) =>
    ArchiveFile.bytes(name, utf8.encode(target))
      ..symbolicLink = target
      ..mode = 0xa1ff;

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('panache archive ');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });
  Future<String> extract(
    List<ArchiveFile> entries, {
    String platform = 'windows-x64',
  }) {
    final archive = Archive();
    for (final file in entries) {
      archive.addFile(file);
    }
    final bytes = ZipEncoder().encodeBytes(archive, level: 9);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 46 <= bytes.length; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        bytes[i + 5] = 3;
      }
    }
    final input = File(p.join(root.path, 'input.zip'))..writeAsBytesSync(bytes);
    return extractPackage(input.path, p.join(root.path, 'stage'), platform);
  }

  final failure = throwsA(isA<UpdaterFailure>());
  for (final name in [
    '../escape',
    '/absolute',
    'Panache/../escape',
    'Panache/..\\escape',
    'C:/escape',
    'Panache/CON.txt',
    'Panache/bad.',
    'Panache//empty',
  ]) {
    test('rejects unsafe path $name', () async {
      await expectLater(
        extract([
          ArchiveFile.bytes(name, [1, 2, 3]),
        ]),
        failure,
      );
      expect(File(p.join(root.path, 'escape')).existsSync(), false);
    });
  }
  test('case aliases are ambiguous and rejected on every platform', () async {
    await expectLater(
      extract([
        ArchiveFile.bytes('Panache/A', [1]),
        ArchiveFile.bytes('Panache/a', [2]),
      ]),
      failure,
    );
  });
  test('a file cannot serve as a directory prefix', () async {
    await expectLater(
      extract([
        ArchiveFile.bytes('Panache/parent', [1]),
        ArchiveFile.bytes('Panache/parent/child', [2]),
      ]),
      failure,
    );
  });
  test('links are rejected outside a mac bundle', () async {
    await expectLater(
      extract([
        ArchiveFile.bytes('Panache/file', [1]),
        link('Panache/link', 'file'),
      ]),
      failure,
    );
  });
  for (final target in ['/etc/passwd', '../../outside', 'b']) {
    test('rejects mac absolute external or cyclic link $target', () async {
      await expectLater(
        extract([
          ArchiveFile.bytes('Panache.app/file', [1]),
          link('Panache.app/a', target),
          if (target == 'b') link('Panache.app/b', 'a'),
        ], platform: 'macos-arm64'),
        failure,
      );
    });
  }
  test(
    'entry contents may not be extracted through a symlink prefix',
    () async {
      await expectLater(
        extract([
          ArchiveFile.bytes('Panache.app/real/file', [1]),
          link('Panache.app/alias', 'real'),
          ArchiveFile.bytes('Panache.app/alias/child', [2]),
        ], platform: 'macos-arm64'),
        failure,
      );
    },
  );
  test('internal framework links and signature files are preserved, AppleDouble is ignored', () async {
    if (Platform.isWindows) return; // Windows hosts do not have permission to create Unix framework links.
    final path = await extract([
      ArchiveFile.bytes('Panache.app/Contents/Frameworks/F/Versions/A/F', [
        1,
        2,
        3,
      ]),
      ArchiveFile.bytes('Panache.app/Contents/_CodeSignature/CodeResources', [
        4,
      ]),
      link('Panache.app/Contents/Frameworks/F/Versions/Current', 'A'),
      link('Panache.app/Contents/Frameworks/F/F', 'Versions/Current/F'),
      ArchiveFile.bytes('__MACOSX/._Panache.app', [0]),
    ], platform: 'macos-arm64');
    expect(File(p.join(path, 'Contents/Frameworks/F/F')).readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    expect(Link(p.join(path, 'Contents/Frameworks/F/F')).existsSync(), true);
    expect(
      File(p.join(path, 'Contents/_CodeSignature/CodeResources'))
          .readAsBytesSync(),
      [4],
    );
  });
  test(
    'excessive expansion is rejected before writing decompressed bytes',
    () async {
      final entry = ArchiveFile.bytes(
        'Panache/bomb',
        List.filled(2 * 1024 * 1024, 0),
      );
      await expectLater(extract([entry]), failure);
    },
  );
  test('non-archive input cannot leave an executable stage', () async {
    final input = File(p.join(root.path, 'input.zip'))
      ..writeAsStringSync('bad');
    await expectLater(
      extractPackage(input.path, p.join(root.path, 'stage'), 'windows-x64'),
      failure,
    );
    expect(
      File(p.join(root.path, 'stage', 'Panache', 'handwriting_app.exe'))
          .existsSync(),
      false,
    );
  });
  for (final type in ['1', '3', '6']) {
    test(
      'tar hard links devices and FIFO type $type are rejected before extraction',
      () async {
        final archive = Archive()
          ..addFile(ArchiveFile.bytes('Panache/file', [1, 2, 3]));
        final tar = TarEncoder().encodeBytes(archive);
        tar[156] = type.codeUnitAt(0);
        for (var i = 148; i < 156; i++) {
          tar[i] = 32;
        }
        final sum = tar.take(512).fold<int>(0, (a, b) => a + b);
        final checksum = '${sum.toRadixString(8).padLeft(6, '0')}\x00 ';
        for (var i = 0; i < 8; i++) {
          tar[148 + i] = checksum.codeUnitAt(i);
        }
        final input = File(p.join(root.path, 'input.tar.gz'))
          ..writeAsBytesSync(GZipEncoder().encodeBytes(tar));
        await expectLater(
          extractPackage(input.path, p.join(root.path, 'stage'), 'linux-x64'),
          failure,
        );
      },
    );
  }
}
