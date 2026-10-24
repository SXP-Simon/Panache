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
    Map<String, Upload> files, {
    String? taskId,
  }) => submission.future;
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

class StoppingApi extends ControlledApi {
  Completer<void> exit = Completer<void>();
  bool failStop = false;
  bool failStatus = false;
  @override
  Future<Map<String, dynamic>> status(String id) {
    if (failStatus) return Future.error(ApiException('status unavailable'));
    return super.status(id);
  }

  @override
  Future<void> cancelTask(String id) async {
    cancelled.add(id);
    if (failStop) throw ApiException('offline');
    await exit.future;
  }
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
    'cancel holds generation slot until engine exits and preserves exports',
    () async {
      final api = StoppingApi();
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      w.exportBytes = Uint8List.fromList([7]);
      final generation = w.generate();
      api.submission.complete('task');
      await api.previewRequested.future;
      final stopping = w.cancel();
      final duplicate = w.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(w.busy, isTrue);
      expect(w.phase, 'cancelling');
      expect(await w.generate(), isFalse);
      expect(api.cancelled, ['task']);
      api.rendered.complete([
        Uint8List.fromList([8]),
      ]);
      expect(await generation, isFalse);
      expect(w.busy, isTrue);
      expect(w.pages, isEmpty);
      expect(w.exportBytes, [7]);
      api.exit.complete();
      await Future.wait([stopping, duplicate]);
      expect(w.busy, isFalse);
      expect(w.phase, 'cancelled');
      w.dispose();
    },
  );

  test('failed stop keeps slot locked and can be retried safely', () async {
    final api = StoppingApi()..failStop = true;
    final w = Workspace(api: api)..text = 'draft';
    w.settings.font = 'test.ttf';
    final generation = w.generate();
    api.submission.complete('task');
    await api.previewRequested.future;
    await w.cancel();
    expect(w.busy, isTrue);
    expect(w.stopping, isFalse);
    expect(w.error, 'offline');
    expect(await w.generate(), isFalse);
    api.failStop = false;
    final retry = w.cancel();
    api.exit.complete();
    await retry;
    expect(w.busy, isFalse);
    expect(w.error, isEmpty);
    api.rendered.complete([]);
    expect(await generation, isFalse);
    w.dispose();
  });

  test(
    'polling failure stops the still-running renderer before unlocking',
    () async {
      final api = StoppingApi()..failStatus = true;
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      final generation = w.generate();
      api.submission.complete('task');
      await Future<void>.delayed(Duration.zero);
      expect(w.busy, isTrue);
      expect(w.phase, 'cancelling');
      expect(api.cancelled, ['task']);
      api.exit.complete();
      expect(await generation, isFalse);
      expect(w.busy, isFalse);
      expect(w.error, 'status unavailable');
      w.dispose();
    },
  );

  test(
    'submission failure after cancellation releases slot without a task',
    () async {
      final api = ControlledApi();
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      final generation = w.generate();
      final stopped = w.cancel();
      api.submission.completeError(ApiException('invalid upload'));
      await stopped;
      expect(await generation, isFalse);
      expect(w.busy, isFalse);
      expect(api.cancelled, isEmpty);
      expect(w.text, 'draft');
      w.dispose();
    },
  );

  test(
    'damaged settings and image entries do not discard readable draft',
    () async {
      final storage = MemoryStorage();
      storage.values['flutter.workspace'] = jsonEncode({
        'text': '保留我的草稿',
        'settings': 12,
        'images': {'1': 'data:image/png;base64,AA==', 'invalid': 42},
      });
      final w = Workspace(api: ControlledApi(), storage: storage);
      await w.initialize();
      expect(w.text, '保留我的草稿');
      expect(w.images.keys, ['1']);
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
      final cancellation = w.cancel();
      expect(w.busy, isTrue);
      expect(w.phase, 'cancelling');
      expect(await w.generate(), isFalse);
      api.submission.complete('late-task');
      await cancellation;
      expect(await generation, isFalse);
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
      expect(await generation, isFalse);
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
    expect(await generation, isFalse);
    expect(w.pages, isEmpty);
    expect(w.error, isEmpty);
  });

  test(
    'preset failures are reported and do not poison subsequent saves',
    () async {
      final storage = MemoryStorage()..fail = true;
      final w = Workspace(api: ControlledApi(), storage: storage);
      expect(await w.savePreset(), isFalse);
      expect(w.error, contains('disk full'));
      expect(storage.values.containsKey('flutter.preset'), isFalse);
      storage.fail = false;
      expect(await w.savePreset(), isTrue);
      w.dispose();
      await w.persist();
    },
  );

  test(
    'invalid image data and nonnumeric IDs are excluded without losing text',
    () async {
      final storage = MemoryStorage();
      storage.values['flutter.workspace'] = jsonEncode({
        'text': '正文 ![插图 1] ![插图 2]',
        'images': {
          '1': 'data:image/png;base64,AA==',
          '2': 'data:image/png;base64,%%%',
          '3': 'data:image/png;base64,A',
          '4': 'https://example.invalid/picture.png',
          'not-a-number': 'data:image/png;base64,AA==',
        },
      });
      final w = Workspace(api: ControlledApi(), storage: storage);
      await w.initialize();
      expect(w.text, '正文 ![插图 1] ![插图 2]');
      expect(w.images.keys, ['1']);
      w.dispose();
      await w.persist();
    },
  );

  test(
    'generation returns success only after publishing its own result',
    () async {
      final api = ControlledApi();
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      final generation = w.generate();
      api.submission.complete('task');
      await api.previewRequested.future;
      api.rendered.complete([
        Uint8List.fromList([2]),
      ]);
      expect(await generation, isTrue);
      expect(w.pages.single, [2]);
      w.dispose();
    },
  );

  test(
    'invalid input and failed submissions return false despite old pages',
    () async {
      final api = ControlledApi();
      final w = Workspace(api: api)
        ..pages = [
          Uint8List.fromList([1]),
        ];
      expect(await w.generate(), isFalse);
      w.text = 'draft';
      w.settings.font = 'test.ttf';
      final generation = w.generate();
      api.submission.completeError(ApiException('failed'));
      expect(await generation, isFalse);
      expect(w.pages.single, [1]);
      w.dispose();
    },
  );

  test(
    'cancelled previous caller cannot claim a later successful result',
    () async {
      final oldApi = ControlledApi();
      final newApi = ControlledApi();
      final w = Workspace(api: oldApi)..text = 'draft';
      w.settings.font = 'test.ttf';
      final oldGeneration = w.generate();
      oldApi.submission.complete('old-task');
      await oldApi.previewRequested.future;
      await w.cancel();
      w.api = newApi;
      final newGeneration = w.generate();
      newApi.submission.complete('new-task');
      await newApi.previewRequested.future;
      newApi.rendered.complete([
        Uint8List.fromList([2]),
      ]);
      expect(await newGeneration, isTrue);
      oldApi.rendered.complete([
        Uint8List.fromList([1]),
      ]);
      expect(await oldGeneration, isFalse);
      expect(w.pages.single, [2]);
      w.dispose();
      oldApi.close();
    },
  );
}
