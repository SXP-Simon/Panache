import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

// Each blocking operation runs outside the UI isolate. Buffers have one owner.
Map<String, dynamic> _invoke(String request, String? libraryPath) {
  final library = libraryPath != null
      ? DynamicLibrary.open(libraryPath)
      : Platform.isAndroid
      ? DynamicLibrary.open('libhandwriting_bridge.so')
      : DynamicLibrary.process();
  final call = library.lookupFunction<_CallNative, _CallDart>(
    'handwriting_bridge_call',
  );
  final free = library.lookupFunction<_FreeNative, _FreeDart>(
    'handwriting_bridge_free',
  );
  final input = request.toNativeUtf8();
  Pointer<Utf8>? output;
  try {
    output = call(input);
    if (output.address == 0) throw StateError('Native engine returned null');
    return jsonDecode(output.toDartString()) as Map<String, dynamic>;
  } finally {
    calloc.free(input);
    if (output != null && output.address != 0) free(output);
  }
}

class MobileHandwritingApi extends HandwritingApi {
  MobileHandwritingApi._(
    this.dataDirectory,
    this.fontDirectory,
    this.libraryPath,
  ) : super('local://handwriting');
  final String dataDirectory, fontDirectory;
  final String? libraryPath;
  bool _closed = false;

  static Future<MobileHandwritingApi> bundled() async {
    final root = await getTemporaryDirectory();
    final directory = Directory('${root.path}/handwriting-engine');
    final fonts = Directory('${root.path}/handwriting-fonts');
    await fonts.create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final key in manifest.listAssets().where(
      (key) => key.startsWith('packages/handwriting_assets/font_assets/'),
    )) {
      final file = File('${fonts.path}/${key.split('/').last}');
      final bytes = await rootBundle.load(key);
      if (!await file.exists() || await file.length() != bytes.lengthInBytes) {
        final partial = File('${file.path}.partial');
        await partial.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
        await partial.rename(file.path);
      }
    }
    return open(dataDirectory: directory.path, fontDirectory: fonts.path);
  }

  static Future<MobileHandwritingApi> open({
    required String dataDirectory,
    required String fontDirectory,
    String? libraryPath,
  }) async {
    await Directory(dataDirectory).create(recursive: true);
    final api = MobileHandwritingApi._(
      dataDirectory,
      fontDirectory,
      libraryPath,
    );
    try {
      // Hot restart can leave a native worker alive; cancel and wait before cleanup.
      for (var attempt = 0; ; attempt++) {
        try {
          await api.call('reset');
          break;
        } on ApiException catch (e) {
          if (e.waitSeconds == null || attempt >= 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      await api.call('fonts');
      return api;
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  Future<dynamic> call(
    String command, {
    Map<String, String> fields = const {},
    Map<String, dynamic> files = const {},
    String id = '',
  }) async {
    if (_closed) throw StateError('Local engine closed');
    final request = jsonEncode({
      'command': command,
      'data_dir': dataDirectory,
      'font_dir': fontDirectory,
      'fields': fields,
      'files': files,
      'task_id': id,
    });
    final path = libraryPath;
    final response = await Isolate.run(() => _invoke(request, path));
    if (_closed && command == 'submit' && response['ok'] == true) {
      final cancel = jsonEncode({
        'command': 'cancel',
        'data_dir': dataDirectory,
        'font_dir': fontDirectory,
        'task_id': (response['data'] as Map)['task_id'],
      });
      await Isolate.run(() => _invoke(cancel, path));
      throw StateError('Local engine closed during submission');
    }
    if (response['ok'] != true) {
      throw ApiException(
        '${response['message']}',
        waitSeconds: response['code'] == 'queue_full' ? 1 : null,
      );
    }
    return response['data'];
  }

  Future<Map<String, dynamic>> stage(Map<String, Upload> uploads) async {
    final parent = await Directory('$dataDirectory/uploads')
        .create(recursive: true);
    final directory = await parent.createTemp('request-');
    final paths = <String, dynamic>{};
    try {
      for (final entry in uploads.entries) {
        if (entry.value.bytes.length > 16 * 1024 * 1024) {
          throw ApiException('文件超过移动端限制 / File exceeds mobile limit');
        }
        final path = '${directory.path}/${paths.length}.bin';
        await File(path).writeAsBytes(entry.value.bytes);
        paths[entry.key] = {'name': entry.value.name, 'path': path};
      }
      return paths;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> removeUploads(Map<String, dynamic> paths) async {
    final directories = paths.values
        .map((file) => File(file['path'] as String).parent.path)
        .toSet();
    for (final path in directories) {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  @override
  Future<dynamic> getJson(String path) => switch (path) {
    '/api/fonts_info' => call('fonts'),
    '/api/version' => call('version'),
    _ => throw UnsupportedError(path),
  };
  @override
  Future<Map<String, dynamic>> importFile(String path, Upload file) async {
    final paths = await stage({'file': file});
    try {
      return Map<String, dynamic>.from(
        await call(
          path == '/api/textfileprocess' ? 'import' : 'identify',
          files: paths,
        ) as Map,
      );
    } finally {
      await removeUploads(paths);
    }
  }

  final Map<String, Map<String, dynamic>> _uploads = {};
  @override
  Future<String> submit(
    Map<String, String> fields,
    Map<String, Upload> files,
  ) async {
    final paths = files.isEmpty ? <String, dynamic>{} : await stage(files);
    try {
      final result = await call('submit', fields: fields, files: paths) as Map;
      final id = result['task_id'] as String;
      _uploads[id] = paths;
      return id;
    } catch (_) {
      await removeUploads(paths);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> status(String id) async {
    final value = Map<String, dynamic>.from(
      await call('status', id: id) as Map,
    );
    if (['completed', 'failed', 'cancelled'].contains(value['task_status'])) {
      final paths = _uploads.remove(id);
      if (paths != null) await removeUploads(paths);
    }
    return value;
  }

  @override
  Future<List<Uint8List>> preview(String id) async {
    final result = await call('result', id: id) as Map;
    return [
      for (final path in result['pages'] as List)
        await File(path as String).readAsBytes(),
    ];
  }

  @override
  Future<http.Response> result(String id) async {
    final result = await call('result', id: id) as Map;
    final path =
        result['result'] as String? ??
        (result['pages'] as List).first as String;
    return http.Response.bytes(
      await File(path).readAsBytes(),
      200,
      headers: {'content-type': result['content_type'] as String},
    );
  }

  @override
  bool get supportsCancel => true;
  @override
  Future<void> cancelTask(String id) async {
    await call('cancel', id: id);
  }

  Future<void> cancelAll() async {
    if (!_closed) await call('cancel_all');
  }

  @override
  void close() {
    if (_closed) return;
    // Capture request before closing; cancellation remains independent of UI lifetime.
    final request = jsonEncode({
      'command': 'cancel_all',
      'data_dir': dataDirectory,
      'font_dir': fontDirectory,
    });
    final path = libraryPath;
    unawaited(
      Isolate.run(() => _invoke(request, path))
          .catchError((Object _) => <String, dynamic>{}),
    );
    _closed = true;
    super.close();
  }
}
