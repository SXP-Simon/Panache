import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'platform_files.dart';
import 'protocol.dart';

const maxExtractedBytes = 1536 * 1024 * 1024;
const maxEntryBytes = 512 * 1024 * 1024;
const maxEntries = 30000;

String archivePath(String value) {
  final path = value.endsWith('/')
      ? value.substring(0, value.length - 1)
      : value;
  if (path.isEmpty ||
      path.length > 2048 ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\x00') ||
      path
          .split('/')
          .any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                part.endsWith(' ') ||
                part.endsWith('.') ||
                RegExp(
                  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          )) {
    reject('unsafe_archive_path');
  }
  return path;
}

void _preflightZip(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    final count = length < 65557 ? length : 65557;
    file.setPositionSync(length - count);
    final bytes = file.readSync(count), data = ByteData.sublistView(bytes);
    var eocd = -1;
    for (var index = count - 22; index >= 0; index--) {
      if (data.getUint32(index, Endian.little) == 0x06054b50 &&
          index + 22 + data.getUint16(index + 20, Endian.little) == count) {
        eocd = index;
        break;
      }
    }
    if (eocd < 0 ||
        data.getUint16(eocd + 4, Endian.little) != 0 ||
        data.getUint16(eocd + 6, Endian.little) != 0 ||
        data.getUint16(eocd + 8, Endian.little) !=
            data.getUint16(eocd + 10, Endian.little) ||
        data.getUint16(eocd + 10, Endian.little) > maxEntries ||
        data.getUint32(eocd + 12, Endian.little) > 64 * 1024 * 1024 ||
        data.getUint32(eocd + 16, Endian.little) +
                data.getUint32(eocd + 12, Endian.little) >
            length - 22) {
      reject('invalid_zip');
    }
  } finally {
    file.closeSync();
  }
}

void _preflightTar(String path) {
  final input = InputFileStream(path);
  try {
    var count = 0;
    while (input.length >= 512) {
      final header = input.readBytes(512).toUint8List();
      if (header.every((byte) => byte == 0)) break;
      if (++count > maxEntries * 2) reject('archive_too_large');
      final type = String.fromCharCode(header[156]);
      if (!{'0', '\x00', '5', 'x', 'g', 'L', 'K'}.contains(type)) {
        reject('archive_link_or_special');
      }
      final size = int.tryParse(
        String.fromCharCodes(header.sublist(124, 136))
            .replaceAll('\x00', '')
            .trim(),
        radix: 8,
      );
      if (size == null ||
          size < 0 ||
          size > maxEntryBytes ||
          ({'x', 'g', 'L', 'K'}.contains(type) && size > 65536)) {
        reject('archive_too_large');
      }
      final padded = ((size + 511) ~/ 512) * 512;
      if (padded > input.length) reject('truncated_archive');
      input.skip(padded);
    }
  } finally {
    input.closeSync();
  }
}

class _Entries {
  _Entries(this.platform);
  final String platform;
  final Map<String, ArchiveFile> files = {};
  final Set<String> folded = {};
  int total = 0;
  void add(ArchiveFile entry) {
    final name = archivePath(entry.name);
    if (files.length >= maxEntries || !folded.add(name.toLowerCase())) {
      reject('duplicate_archive_entry');
    }
    final mode = entry.mode & 0xf000;
    if (mode != 0 && mode != 0x8000 && mode != 0x4000 && mode != 0xa000) {
      reject('archive_link_or_special');
    }
    if (entry.size < 0 ||
        entry.size > maxEntryBytes ||
        (total += entry.size) > maxExtractedBytes) {
      reject('archive_too_large');
    }
    if (entry.isSymbolicLink &&
        (platform != 'macos-arm64' ||
            entry.size > 4096 ||
            name.startsWith('__MACOSX/'))) {
      reject('archive_link_or_special');
    }
    files[name] = entry;
  }

  void validate() {
    final root = platform == 'macos-arm64' ? 'Panache.app' : 'Panache';
    for (final MapEntry(key: name, value: entry) in files.entries) {
      if (name == '__MACOSX' || name.startsWith('__MACOSX/')) {
        if (platform != 'macos-arm64') reject('unexpected_archive_root');
        continue;
      }
      if (name != root && !name.startsWith('$root/')) {
        reject('unexpected_archive_root');
      }
      var parent = p.posix.dirname(name);
      while (parent != '.') {
        final ancestor = files[parent];
        if (ancestor != null &&
            (!ancestor.isDirectory || ancestor.isSymbolicLink)) {
          reject('archive_prefix_conflict');
        }
        parent = p.posix.dirname(parent);
      }
      if (entry.isSymbolicLink) _resolve(name, root, {});
    }
  }

  String _resolve(String path, String root, Set<String> seen) {
    final parts = path.split('/');
    for (var index = 1; index <= parts.length; index++) {
      final prefix = parts.take(index).join('/'), entry = files[prefix];
      if (entry?.isSymbolicLink != true) continue;
      if (!seen.add(prefix) || seen.length > 32) reject('cyclic_archive_link');
      final link = entry!.symbolicLink!;
      if (link.startsWith('/') ||
          link.contains('\\') ||
          link.contains(':') ||
          link.contains('\x00')) {
        reject('unsafe_archive_link');
      }
      final target = p.posix.normalize(
        p.posix.join(
          p.posix.dirname(prefix),
          link,
          parts.skip(index).join('/'),
        ),
      );
      if (target != root && !target.startsWith('$root/')) {
        reject('unsafe_archive_link');
      }
      return _resolve(target, root, seen);
    }
    if (!files.containsKey(path) &&
        !files.keys.any((name) => name.startsWith('$path/'))) {
      reject('dangling_archive_link');
    }
    return path;
  }
}

/// All paths and entry types are checked before any extracted file is written.
Future<String> extractPackage(
  String source,
  String destination,
  String platform,
) async {
  if (Directory(destination).existsSync() &&
      Directory(destination).listSync().isNotEmpty) {
    reject('nonempty_stage');
  }
  Directory(destination).createSync(recursive: true);
  final entries = _Entries(platform);
  InputFileStream? input;
  Archive? archive;
  String? tar;
  try {
    if (source.endsWith('.zip')) {
      _preflightZip(source);
      input = InputFileStream(source);
      final directory = ZipDirectory()..read(input);
      for (final header in directory.fileHeaders) {
        final local = header.file!;
        if (header.filename != local.filename ||
            header.uncompressedSize > maxEntryBytes ||
            (header.uncompressedSize > 1024 * 1024 &&
                header.uncompressedSize > (header.compressedSize + 1) * 300)) {
          reject('invalid_zip');
        }
        final type = header.externalFileAttributes >> 16 & 0xf000;
        if (type != 0 && type != 0x8000 && type != 0x4000 && type != 0xa000) {
          reject('archive_link_or_special');
        }
        if (type == 0xa000 && header.versionMadeBy >> 8 != 3) {
          reject('archive_link_or_special');
        }
        if (type == 0xa000 && header.uncompressedSize > 4096) {
          reject('archive_too_large');
        }
        final name = archivePath(header.filename);
        if (!entries.folded.add(name.toLowerCase())) {
          reject('duplicate_archive_entry');
        }
      }
      entries.folded.clear();
      input.closeSync();
      input = InputFileStream(source);
      archive = ZipDecoder().decodeStream(
        input,
        verify: true,
        callback: entries.add,
      );
    } else if (source.endsWith('.tar.gz')) {
      tar = '$destination.tar';
      input = InputFileStream(source);
      final output = OutputFileStream(tar);
      try {
        GZipDecoder().decodeStream(
          input,
          output,
          verify: true,
          maxOutputSize: maxExtractedBytes,
        );
      } finally {
        output.closeSync();
        input.closeSync();
      }
      _preflightTar(tar);
      input = InputFileStream(tar);
      archive = TarDecoder().decodeStream(
        input,
        verify: true,
        callback: entries.add,
      );
    } else {
      reject('unsupported_archive');
    }
    entries.validate();
    final regular = Archive();
    for (final MapEntry(key: name, value: entry) in entries.files.entries) {
      if (!entry.isSymbolicLink &&
          name != '__MACOSX' &&
          !name.startsWith('__MACOSX/')) {
        regular.add(entry);
      }
    }
    extractArchiveToDiskSync(regular, destination, maxSize: maxExtractedBytes);
    for (final MapEntry(key: name, value: entry) in entries.files.entries) {
      if (name == '__MACOSX' || name.startsWith('__MACOSX/')) continue;
      final target = p.joinAll([destination, ...name.split('/')]);
      if (entry.isSymbolicLink) {
        Link(target).createSync(entry.symbolicLink!, recursive: true);
      } else {
        if (entry.isFile && File(target).lengthSync() != entry.size) {
          reject('truncated_archive');
        }
        setMode(
          target,
          entry.isDirectory
              ? 0x1ed
              : (entry.unixPermissions == 0 ? 0x1a4 : entry.unixPermissions),
        );
      }
    }
    return p.join(
      destination,
      platform == 'macos-arm64' ? 'Panache.app' : 'Panache',
    );
  } finally {
    await archive?.clear();
    input?.closeSync();
    if (tar != null && File(tar).existsSync()) File(tar).deleteSync();
  }
}
