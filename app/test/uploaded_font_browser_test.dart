import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/uploaded_font_storage.dart';

void main() {
  test(
    'IndexedDB retains binary font across adapters and removes it',
    () async {
      final first = createUploadedFontStorage();
      await first.write(Upload('我的字体.ttf', Uint8List.fromList([0, 255, 1])));
      final restarted = createUploadedFontStorage();
      final font = await restarted.read();
      expect(font?.name, '我的字体.ttf');
      expect(font?.bytes, [0, 255, 1]);
      await restarted.write(Upload('new.otf', Uint8List.fromList([5])));
      expect((await first.read())?.bytes, [5]);
      await first.write(null);
      expect(await restarted.read(), isNull);
    },
    skip: !kIsWeb,
  );
}
