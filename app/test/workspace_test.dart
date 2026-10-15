import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/workspace_storage.dart';

class MemoryStorage implements WorkspaceStorage {
  final values = <String, String>{};
  final writes = <String>[];
  Completer<void>? gate;
  bool fail = false;
  @override
  String? read(String key) => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes.add(value);
    await gate?.future;
    if (fail) throw StateError('disk full');
    values[key] = value;
  }
}

class ControlledApi extends HandwritingApi {
  ControlledApi() : super('http://example.invalid');
  final submission = Completer<String>();
  final rendered = Completer<List<Uint8List>>();
  final cancelled = <String>[];
  final previewRequested = Completer<void>();
  @override
  bool get supportsCancel => true;
  @override
  Future<dynamic> getJson(String path) async =>
      path == '/api/fonts_info' ? ['test.ttf'] : {'version': 'test'};
  @override
  Future<String> submit(
    Map<String, String> fields,
    Map<String, Upload> files,
  ) => submission.future;
  @override
  Future<Map<String, dynamic>> status(String id) async => {
    'status': 'completed',
  };
  @override
  Future<List<Uint8List>> preview(String id) {
    previewRequested.complete();
    return rendered.future;
  }

  @override
  Future<void> cancelTask(String id) async => cancelled.add(id);
}

class ConnectionApi extends ControlledApi {
  final fontsRequests = <Completer<List<String>>>[];
  @override
  Future<dynamic> getJson(String path) {
    if (path != '/api/fonts_info') return Future.value({'version': 'test'});
    final request = Completer<List<String>>();
    fontsRequests.add(request);
    return request.future;
  }
}

void main() {
  test(
    'damaged settings and image entries do not discard readable draft',
    () async {
      final storage = MemoryStorage();
      storage.values['flutter.workspace'] = jsonEncode({
        'text': '保留我的草稿',
        'settings': 12,
        'images': {'valid': 'data:image/png;base64,AA==', 'invalid': 42},
      });
      final w = Workspace(api: ControlledApi(), storage: storage);
      await w.initialize();
      expect(w.text, '保留我的草稿');
      expect(w.images.keys, ['valid']);
      expect(w.settings.valid, isTrue);
      w.dispose();
      await w.persist();
    },
  );

  test('dispose flushes last input before debounce fires', () async {
    final storage = MemoryStorage();
    final w = Workspace(api: ControlledApi(), storage: storage);
    w.text = '最后输入';
    w.edit();
    w.dispose();
    await w.persist();
    expect(jsonDecode(storage.values['flutter.workspace']!)['text'], '最后输入');
  });

  test(
    'writes serialize immutable snapshots and recover after failure',
    () async {
      final storage = MemoryStorage()..gate = Completer<void>();
      final w = Workspace(api: ControlledApi(), storage: storage);
      w.text = 'first';
      final first = w.persist();
      w.text = 'last';
      final last = w.persist();
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes.length, 1);
      storage.gate!.complete();
      await Future.wait([first, last]);
      expect(jsonDecode(storage.values['flutter.workspace']!)['text'], 'last');
      storage.fail = true;
      await w.persist();
      expect(w.error, contains('disk full'));
      storage.fail = false;
      w.text = 'recovered';
      await w.persist();
      expect(
        jsonDecode(storage.values['flutter.workspace']!)['text'],
        'recovered',
      );
      w.dispose();
      await w.persist();
    },
  );

  test(
    'cancellation before submit resolves cancels late task without results',
    () async {
      final api = ControlledApi();
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      final generation = w.generate();
      expect(w.busy, isTrue);
      await w.cancel();
      api.submission.complete('late-task');
      await generation;
      expect(api.cancelled, ['late-task']);
      expect(w.busy, isFalse);
      expect(w.phase, 'cancelled');
      expect(w.pages, isEmpty);
      w.dispose();
    },
  );

  test(
    'cancel discards delayed preview without replacing existing pages',
    () async {
      final api = ControlledApi();
      final original = Uint8List.fromList([1]);
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      w.pages = [original];
      final generation = w.generate();
      api.submission.complete('task');
      await api.previewRequested.future;
      await w.cancel();
      api.rendered.complete([
        Uint8List.fromList([2]),
      ]);
      await generation;
      expect(w.pages.single, same(original));
      expect(w.progress, isNot(100));
      expect(w.phase, 'cancelled');
      w.dispose();
    },
  );

  test('late old connection cannot overwrite latest font list', () async {
    final api = ConnectionApi();
    final w = Workspace(api: api);
    final oldConnection = w.connect();
    final newConnection = w.connect();
    api.fontsRequests.last.complete(['new.ttf']);
    await newConnection;
    api.fontsRequests.first.complete(['old.ttf']);
    await oldConnection;
    expect(w.fonts, ['new.ttf']);
    expect(w.settings.font, 'new.ttf');
    w.dispose();
  });

  test('disposed generation cannot publish delayed task output', () async {
    final api = ControlledApi();
    final w = Workspace(api: api)..text = 'draft';
    w.settings.font = 'test.ttf';
    final generation = w.generate();
    api.submission.complete('task');
    await api.previewRequested.future;
    w.dispose();
    api.rendered.complete([
      Uint8List.fromList([2]),
    ]);
    await generation;
    expect(w.pages, isEmpty);
    expect(w.error, isEmpty);
  });
}
