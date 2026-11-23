import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/ink_page.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/utils/ink_effects.dart';
import 'package:handwriting_app/utils/paper_exif.dart';

void main() {
  test('camera input survives a preset and an older preset clears it', () {
    final settings = Settings()
      ..camera.addAll({'camera_model': 'Test phone', 'camera_iso': '320'});
    final restored = Settings()..restore(settings.toJson());
    expect(restored.form('a', preview: false, pdf: true)['camera_iso'], '320');
    expect(restored.camera['camera_model'], 'Test phone');
    expect(Settings.validCameraValue('camera_iso', '65536'), isFalse);
    restored.restore({});
    expect(
      restored.form('a', preview: true, pdf: false),
      isNot(contains('camera_model')),
    );
  });

  testWidgets(
    'saving an ink page inserts one EXIF chunk without changing pixels',
    (tester) async {
      // A one-pixel PNG and a little-endian TIFF with a Model field ("ABC").
      final paper = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==',
      );
      final exif = Uint8List.fromList([
        73,
        73,
        42,
        0,
        8,
        0,
        0,
        0,
        1,
        0,
        16,
        1,
        2,
        0,
        4,
        0,
        0,
        0,
        65,
        66,
        67,
        0,
        0,
        0,
        0,
        0,
      ]);
      final json = {'paper': base64Encode(paper), 'ink': base64Encode(paper)};
      final legacy = InkPage.fromJson(json);
      expect(legacy.cameraExif, isNull);
      final page = InkPage.fromJson({
        ...json,
        'camera_exif': base64Encode(exif),
      });
      await tester.runAsync(() async {
        final original = await compositeInkPage(legacy, defaultInkLook);
        final tagged = await compositeInkPage(page, defaultInkLook);
        expect(tagged, withPaperExif(original, exif));
        final chunk = ByteData.sublistView(tagged);
        expect(chunk.getUint32(33), exif.length);
        expect(ascii.decode(tagged.sublist(37, 41)), 'eXIf');
        expect(tagged.sublist(41, 41 + exif.length), exif);
        expect(chunk.getUint32(41 + exif.length), 0x4c44754a);
        expect(tagged.sublist(45 + exif.length), original.sublist(33));
        final decoded = await decodeInkImage(tagged);
        expect(decoded.width, 1);
        decoded.dispose();
      });
    },
  );
}
