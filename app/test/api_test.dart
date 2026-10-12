import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  test('multipart 提交、任务查询、多页预览与插图展开兼容 Python API', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/generate_handwriting') {
        final body = request.body;
        for (final field in [
          'font_size',
          'line_spacing',
          'perturb_theta_sigma',
          'pdf_save',
          'full_preview',
          'font_option',
        ]) {
          expect(body, contains('name="$field"'));
        }
        expect(body, contains('![插图 1](data:image/png;base64,YQ==)'));
        return http.Response('{"task_id":"abc"}', 200);
      }
      if (request.url.path.endsWith('/result')) {
        return http.Response(
          jsonEncode({
            'images': ['YQ==', 'Yg=='],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"status":"success","task_status":"completed","task_progress":100}',
        200,
      );
    });
    final w = Workspace(
      api: HandwritingApi('http://localhost:5005', client: client),
    );
    addTearDown(w.dispose);
    w.settings.font = 'test.ttf';
    w.settings.fullPreview = true;
    w.text = '正文 ![插图 1]';
    w.images['1'] = 'data:image/png;base64,YQ==';
    await w.generate();
    expect(w.error, isEmpty);
    expect(w.busy, isFalse);
    expect(w.pages.map(utf8.decode), ['a', 'b']);
    expect(w.progress, 100);
  });
  test('上传背景时省略 width/height，避免后端覆盖上传图', () async {
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        expect(request.body, isNot(contains('name="width"')));
        expect(request.body, isNot(contains('name="height"')));
        expect(request.body, contains('name="background_image"'));
        return http.Response('{"task_id":"abc"}', 200);
      }
      if (request.url.path.endsWith('/result')) {
        return http.Response.bytes(
          [1, 2],
          200,
          headers: {'content-type': 'image/png'},
        );
      }
      return http.Response(
        '{"status":"success","task_status":"completed"}',
        200,
      );
    });
    final w = Workspace(
      api: HandwritingApi('http://localhost:5005', client: client),
    );
    addTearDown(w.dispose);
    w.settings.font = 'test.ttf';
    w.text = '正文';
    w.background = Upload('paper.png', Uint8List.fromList([1, 2]));
    await w.generate();
    expect(w.error, isEmpty);
    expect(w.pages.single, [1, 2]);
  });
  test('PDF/ZIP 文件与 HTTP 错误处理', () async {
    for (final pdf in [true, false]) {
      final w = Workspace(
        api: HandwritingApi(
          'http://localhost',
          client: MockClient((r) async {
            if (r.method == 'POST') {
              return http.Response('{"task_id":"abc"}', 200);
            }
            if (r.url.path.endsWith('/result')) {
              return http.Response.bytes([37, 80, 68, 70], 200);
            }
            return http.Response(
              '{"status":"success","task_status":"completed"}',
              200,
            );
          }),
        ),
      )..text = '正文';
      w.settings.font = 'test.ttf';
      await w.generate(preview: false, pdf: pdf);
      expect(w.exportExtension, pdf ? 'pdf' : 'zip');
      expect(w.exportBytes, isNotEmpty);
      w.dispose();
    }
    final w = Workspace(
      api: HandwritingApi(
        'http://localhost',
        client: MockClient(
          (r) async => http.Response(
            '{"status":"queue_full","estimated_wait_seconds":60}',
            503,
          ),
        ),
      ),
    )..text = '正文';
    addTearDown(w.dispose);
    w.settings.font = 'test.ttf';
    await w.generate();
    expect(w.error, 'queue:60');
    expect(w.busy, isFalse);
    expect(w.retryAt, isNotNull);
  });
}
