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

  test(
    'large WebP can carry individual camera metadata beyond the image data',
    () {
      const imageSize = 65 * 1024 * 1024;
      const tiff = [73, 73, 42, 0, 8, 0, 0, 0];
      final bytes = Uint8List(12 + 8 + imageSize + 8 + tiff.length);
      final data = ByteData.sublistView(bytes);
      data.setUint32(0, 0x52494646);
      data.setUint32(4, bytes.length - 8, Endian.little);
      data.setUint32(8, 0x57454250);
      data.setUint32(12, 0x56503820);
      data.setUint32(16, imageSize, Endian.little);
      data.setUint32(20 + imageSize, 0x45584946);
      data.setUint32(24 + imageSize, tiff.length, Endian.little);
      bytes.setAll(28 + imageSize, tiff);
      expect(paperExifSource(bytes), tiff);
      data.setUint32(24 + imageSize, tiff.length + 1, Endian.little);
      expect(paperExifSource(bytes), isNull);
    },
  );

  test('JPEG finds EXIF before scan data and ignores other APP1 segments', () {
    const tiff = [73, 73, 42, 0, 8, 0, 0, 0];
    final bytes = Uint8List.fromList([
      0xff, 0xd8,
      0xff, 0xff, 0xd0, // Fill and restart markers have no length.
      0xff, 0xe1, 0, 5, 1, 2, 3,
      0xff, 0xe1, 0, 16, 69, 120, 105, 102, 0, 0, ...tiff,
    ]);
    expect(paperExifSource(bytes), tiff);
    expect(
      paperExifSource(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      isNull,
    );
    bytes[4] = 0xda; // Stop at the start of the image scan.
    expect(paperExifSource(bytes), isNull);
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
        expect(paperExifSource(tagged), exif);
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
