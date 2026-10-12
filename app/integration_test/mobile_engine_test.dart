import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/mobile_api.dart';

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
    id = await api.submit({
      ...fields,
      'text': List.filled(1000, '取消测试').join('\n'),
    }, {});
    await api.cancelTask(id);
    expect((await wait(id))['task_status'], 'cancelled');
    await expectLater(api.preview(id), throwsA(isA<ApiException>()));
  });
}
