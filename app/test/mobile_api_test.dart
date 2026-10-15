import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/mobile_api.dart';

void main() {
  const library = String.fromEnvironment('MOBILE_ENGINE_LIBRARY');
  test(
    '真实 FFI 调用、错误、文件清理和热重启',
    () async {
      final root = await Directory.systemTemp.createTemp('mobile-ffi-');
      addTearDown(() => root.delete(recursive: true));
      Future<MobileHandwritingApi> open() => MobileHandwritingApi.open(
        dataDirectory: root.path,
        fontDirectory: Directory('../assets/font_assets').absolute.path,
        libraryPath: library,
      );
      final api = await open();
      const expectedVersion = String.fromEnvironment('EXPECTED_APP_VERSION');
      if (expectedVersion.isNotEmpty) {
        final version = await api.getJson('/api/version') as Map;
        expect(version['version'], expectedVersion);
      }
      final fonts = await api.getJson('/api/fonts_info') as List;
      expect(fonts.first, '神韵英子楷书.ttf');
      final text = await api.importFile(
        '/api/textfileprocess',
        Upload('测试.txt', utf8.encode('离线测试')),
      );
      expect(text['text'], '离线测试');
      expect(await Directory('${root.path}/uploads').list().length, 0);
      await expectLater(api.call('unknown'), throwsA(isA<ApiException>()));
      await expectLater(api.status('missing'), throwsA(isA<ApiException>()));
      final id = await api.submit({
        'text': '离线生成',
        'width': '420',
        'height': '320',
        'font_size': '32',
        'line_spacing': '45',
        'left_margin': '20',
        'right_margin': '20',
        'top_margin': '20',
        'bottom_margin': '20',
        'seed': '42',
      }, {});
      for (var i = 0; i < 600; i++) {
        final status = await api.status(id);
        if (status['task_status'] == 'completed') break;
        expect(status['task_status'], 'processing', reason: '$status');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect((await api.preview(id)).single.take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      api.close();
      final restarted = await open();
      expect(await Directory('${root.path}/tasks').exists(), false);
      restarted.close();
    },
    skip: library.isEmpty ? '通过 MOBILE_ENGINE_LIBRARY 指定 host cdylib' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
