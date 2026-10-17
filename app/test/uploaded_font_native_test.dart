import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/uploaded_font_storage_native.dart';

void main() {
  test(
    'native font file survives new adapter, replacement and removal',
    () async {
      final directory = await Directory.systemTemp.createTemp('panache-font-');
      addTearDown(() => directory.delete(recursive: true));
      final first = FontStorage(directory: () async => directory);
      expect(await first.read(), isNull);
      await first.write(Upload('字体.ttf', Uint8List.fromList([1, 2, 3])));
      final restarted = FontStorage(directory: () async => directory);
      expect((await restarted.read())?.name, '字体.ttf');
      expect((await restarted.read())?.bytes, [1, 2, 3]);
      await restarted.write(Upload('new.otf', Uint8List.fromList([9])));
      expect((await first.read())?.bytes, [9]);
      await first.write(null);
      expect(await restarted.read(), isNull);
      await first.write(null);
    },
  );
}
