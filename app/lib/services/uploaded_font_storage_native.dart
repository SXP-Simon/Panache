import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'uploaded_font_storage.dart';

class FontStorage implements UploadedFontStorage {
  FontStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<File> _file() async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return File('${directory.path}/uploaded-font.bin');
  }

  @override
  Future<Upload?> read() async {
    final file = await _file();
    return await file.exists() ? decodeFont(await file.readAsBytes()) : null;
  }

  @override
  Future<void> write(Upload? font) async {
    final file = await _file();
    if (font == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(encodeFont(font), flush: true);
    await temporary.rename(file.path);
  }
}
