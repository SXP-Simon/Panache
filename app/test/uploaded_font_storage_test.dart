import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/uploaded_font_storage.dart';
import 'package:handwriting_app/services/workspace.dart';

import 'workspace_test.dart' show MemoryStorage, ControlledApi;

class MemoryFonts implements UploadedFontStorage {
  Upload? value;
  Completer<Upload?>? pendingRead;
  int writes = 0;
  bool fail = false;
  @override
  Future<Upload?> read() async =>
      pendingRead == null ? value : await pendingRead!.future;
  @override
  Future<void> write(Upload? font) async {
    if (fail) throw StateError('font disk full');
    writes++;
    value = font;
  }
}

class MultipleFontsApi extends ControlledApi {
  MultipleFontsApi(this.available);
  final List<String> available;
  @override
  Future<dynamic> getJson(String path) async =>
      path == '/api/fonts_info' ? available : {'version': 'test'};
}

void main() {
  test('bundled font selection survives restart and catalog reorder', () async {
    final storage = MemoryStorage();
    final first = Workspace(
      api: MultipleFontsApi(['first.ttf', 'chosen.ttf']),
      storage: storage,
    );
    await first.initialize();
    first.settings.font = 'chosen.ttf';
    first.edit();
    first.dispose();
    await first.persist();
    final second = Workspace(
      api: MultipleFontsApi(['new.ttf', 'chosen.ttf', 'first.ttf']),
      storage: storage,
    );
    await second.initialize();
    expect(second.settings.font, 'chosen.ttf');
    second.dispose();
    await second.persist();
  });

  test('uploaded font round trips names and bytes, rejects damaged data', () {
    final font = Upload('我的字体.otf', Uint8List.fromList([0, 255, 32]));
    final result = decodeFont(encodeFont(font));
    expect(result.name, font.name);
    expect(result.bytes, font.bytes);
    for (final data in [
      <int>[],
      [0, 0, 0, 9, 1],
      [0, 0, 0, 0, 1],
    ]) {
      expect(() => decodeFont(Uint8List.fromList(data)), throwsFormatException);
    }
  });

  test(
    'restart restores uploaded font without putting bytes in preferences',
    () async {
      final storage = MemoryStorage();
      final fonts = MemoryFonts();
      final original = Upload('我的字体.ttf', Uint8List.fromList([1, 2, 3]));
      final first = Workspace(
        api: ControlledApi(),
        storage: storage,
        fontStorage: fonts,
      );
      await first.initialize();
      first.fontFile = original;
      first.edit();
      await first.persist();
      expect(fonts.writes, 1);
      expect(
        jsonDecode(storage.values['flutter.workspace']!)['uploadedFont'],
        true,
      );
      expect(storage.values['flutter.workspace'], isNot(contains('我的字体')));
      first.text = 'another edit';
      await first.persist();
      expect(fonts.writes, 1);
      first.dispose();
      await first.persist();
      final second = Workspace(
        api: ControlledApi(),
        storage: storage,
        fontStorage: fonts,
      );
      await second.initialize();
      expect(second.fontFile?.name, original.name);
      expect(second.fontFile?.bytes, original.bytes);
      expect(second.settings.font, 'test.ttf');
      second.fontFile = null;
      second.edit();
      await second.persist();
      expect(fonts.value, isNull);
      second.dispose();
      await second.persist();
      final third = Workspace(
        api: ControlledApi(),
        storage: storage,
        fontStorage: fonts,
      );
      await third.initialize();
      expect(third.fontFile, isNull);
      expect(third.settings.font, 'test.ttf');
      third.dispose();
      await third.persist();
    },
  );

  test(
    'failed font writes retry without publishing a saved-font pointer',
    () async {
      final storage = MemoryStorage();
      final fonts = MemoryFonts()..fail = true;
      final w = Workspace(
        api: ControlledApi(),
        storage: storage,
        fontStorage: fonts,
      );
      await w.initialize();
      w.fontFile = Upload('test.ttf', Uint8List.fromList([1]));
      await w.persist();
      expect(w.error, contains('font disk full'));
      expect(storage.values['flutter.workspace'], isNull);
      fonts.fail = false;
      await w.persist();
      expect(fonts.value, isNotNull);
      expect(
        jsonDecode(storage.values['flutter.workspace']!)['uploadedFont'],
        true,
      );
      w.dispose();
      await w.persist();
    },
  );

  test(
    'missing uploaded font falls back without discarding the draft',
    () async {
      final storage = MemoryStorage();
      storage.values['flutter.workspace'] = jsonEncode({
        'text': 'draft',
        'uploadedFont': true,
        'settings': {'font': 'missing.ttf'},
      });
      final w = Workspace(
        api: ControlledApi(),
        storage: storage,
        fontStorage: MemoryFonts(),
      );
      await w.initialize();
      expect(w.fontFile, isNull);
      expect(w.settings.font, 'test.ttf');
      expect(w.text, 'draft');
      w.dispose();
      await w.persist();
    },
  );

  test('font changes during restore win over stale disk bytes', () async {
    final storage = MemoryStorage();
    storage.values['flutter.workspace'] = jsonEncode({'uploadedFont': true});
    final fonts = MemoryFonts()..pendingRead = Completer<Upload?>();
    final w = Workspace(
      api: ControlledApi(),
      storage: storage,
      fontStorage: fonts,
    );
    final initializing = w.initialize();
    await Future<void>.delayed(Duration.zero);
    final latest = Upload('latest.otf', Uint8List.fromList([2]));
    w.fontFile = latest;
    w.edit();
    fonts.pendingRead!.complete(Upload('old.ttf', Uint8List.fromList([1])));
    await initializing;
    expect(w.fontFile, same(latest));
    expect(fonts.value, same(latest));
    w.dispose();
    await w.persist();
  });
}
