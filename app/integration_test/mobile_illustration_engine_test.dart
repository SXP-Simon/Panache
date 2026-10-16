import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:handwriting_app/services/mobile_api.dart';
import 'package:handwriting_app/utils/image_data.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android bundled engine accepts illustration payload over 100k', (
    tester,
  ) async {
    // Deterministic opaque noise resists PNG compression. This exercises actual
    // media bytes rather than padding Markdown with unrelated text.
    const width = 320, height = 240;
    final random = Random(41);
    final pixels = Uint8List(width * height * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = random.nextInt(256);
      pixels[i + 1] = random.nextInt(256);
      pixels[i + 2] = random.nextInt(256);
      pixels[i + 3] = 255;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      rowBytes: width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    final source = await prepareIllustration(png!.buffer.asUint8List());
    expect(source.length, greaterThan(100000));
    expect(base64Decode(source.split(',').last).length, greaterThan(75000));
    final api = await MobileHandwritingApi.bundled();
    addTearDown(api.close);
    final fonts = await api.getJson('/api/fonts_info') as List;
    final text = expandImages('图片前文字\n![插图 1|50%]\n图片后文字', {'1': source});
    final id = await api.submit({
      'text': text,
      'font_option': fonts.first as String,
      'font_size': '30',
      'line_spacing': '42',
      'width': '700',
      'height': '900',
      'left_margin': '40',
      'right_margin': '40',
      'top_margin': '40',
      'bottom_margin': '40',
      'font_size_sigma': '0',
      'line_spacing_sigma': '0',
      'word_spacing_sigma': '0',
      'perturb_x_sigma': '0',
      'perturb_y_sigma': '0',
      'perturb_theta_sigma': '0',
      'ink_depth_sigma': '0',
      'strikethrough_probability': '0',
      'preview': 'true',
      'full_preview': 'true',
      'seed': '42',
    }, {});
    Map<String, dynamic>? finalStatus;
    for (var i = 0; i < 600; i++) {
      final status = await api.status(id);
      if ([
        'completed',
        'failed',
        'cancelled',
      ].contains(status['task_status'])) {
        finalStatus = status;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(finalStatus, isNotNull, reason: 'Native image generation timed out');
    expect(finalStatus!['task_status'], 'completed', reason: '$finalStatus');
    final pages = await api.preview(id);
    expect(pages, hasLength(1));
    final renderedCodec = await ui.instantiateImageCodec(pages.first);
    final rendered = await renderedCodec.getNextFrame();
    expect(rendered.image.width, 700);
    expect(rendered.image.height, 900);
    final rgba = (await rendered.image.toByteData())!;
    var darkPixels = 0;
    for (var i = 0; i < rgba.lengthInBytes; i += 4) {
      if (rgba.getUint8(i) < 100 && rgba.getUint8(i + 3) > 200) darkPixels++;
    }
    expect(
      darkPixels,
      greaterThan(1000),
      reason: 'Rendered page must contain illustration ink',
    );
    rendered.image.dispose();
    renderedCodec.dispose();
  });
}
