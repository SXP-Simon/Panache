import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/mobile_api.dart';
import 'package:handwriting_app/utils/latex.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('随包引擎离线导入、分页预览、PDF/ZIP 和取消', (tester) async {
    final api = await MobileHandwritingApi.bundled();
    addTearDown(api.close);
    final fonts = await api.getJson('/api/fonts_info') as List;
    expect(fonts, contains('神韵英子楷书.ttf'));
    final imported = await api.importFile(
      '/api/textfileprocess',
      Upload('测试.txt', utf8.encode('你好 Flutter')),
    );
    expect(imported['text'], '你好 Flutter');
    final fields = <String, String>{
      'text': '第一页\n---\n第二页',
      'font_option': fonts.first as String,
      'font_size': '32',
      'line_spacing': '45',
      'width': '420',
      'height': '320',
      'left_margin': '20',
      'right_margin': '20',
      'top_margin': '20',
      'bottom_margin': '20',
      'strikethrough_probability': '0',
      'seed': '42',
      'preview': 'true',
      'full_preview': 'true',
    };
    Future<Map<String, dynamic>> wait(String id) async {
      for (var i = 0; i < 600; i++) {
        final status = await api.status(id);
        if ([
          'completed',
          'failed',
          'cancelled',
        ].contains(status['task_status'])) {
          return status;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('Local generation timed out');
    }

    var id = await api.submit(fields, {});
    expect((await wait(id))['task_status'], 'completed');
    final pages = await api.preview(id);
    expect(pages.length, 2);
    expect(pages.first.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    for (final pdf in [true, false]) {
      id = await api.submit({
        ...fields,
        'preview': 'false',
        'pdf_save': '$pdf',
      }, {});
      expect((await wait(id))['task_status'], 'completed');
      final result = await api.result(id);
      expect(
        latin1.decode(result.bodyBytes.take(pdf ? 5 : 2).toList()),
        pdf ? '%PDF-' : 'PK',
      );
    }
    final math = convertLatex(
      r'公式 $x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}$'
      '\n'
      r'$\frac{1}{1+\frac{1}{1+\frac{1}{2}}}$'
      '\n'
      r'$a_{n+1}^{2}+\overrightarrow{AB}+\underline{xy}$'
      '\n---\n'
      r'$\sqrt[12]{\frac{x+1}{x-1}}$'
      '\n'
      r'$\frac{a+b+c+d+e+f+g+h+i+j+k+l+m+n}{x+y}$',
    );
    for (final grid in [false, true]) {
      id = await api.submit({
        ...fields,
        'text': math,
        'height': '420',
        'font_size': '40',
        'line_spacing': '46',
        'isUnderlined': '$grid',
        'grid_layout': '$grid',
        'font_size_sigma': '0',
        'line_spacing_sigma': '0',
        'word_spacing_sigma': '0',
        'perturb_x_sigma': '0',
        'perturb_y_sigma': '0',
        'perturb_theta_sigma': '0',
        'ink_depth_sigma': '0',
      }, {});
      final status = await wait(id);
      expect(status['task_status'], 'completed', reason: '$status');
      final mathPages = await api.preview(id);
      expect(mathPages.length, greaterThanOrEqualTo(2));
      for (final png in mathPages) {
        final codec = await ui.instantiateImageCodec(png);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 420);
        expect(frame.image.height, 420);
        final rgba = (await frame.image.toByteData())!;
        var ink = 0;
        for (var offset = 0; offset < rgba.lengthInBytes; offset += 4) {
          if (rgba.getUint8(offset) < 100 &&
              rgba.getUint8(offset + 1) < 100 &&
              rgba.getUint8(offset + 2) < 100 &&
              rgba.getUint8(offset + 3) > 200) {
            ink++;
          }
        }
        expect(ink, greaterThan(100), reason: 'grid=$grid');
        frame.image.dispose();
        codec.dispose();
      }
    }
    id = await api.submit({
      ...fields,
      'text': List.filled(1000, '取消测试').join('\n'),
    }, {});
    await api.cancelTask(id);
    expect((await wait(id))['task_status'], 'cancelled');
    await expectLater(api.preview(id), throwsA(isA<ApiException>()));
  });
}
