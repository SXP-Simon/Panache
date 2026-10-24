import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  test(
    'known request ID cancels lost submission response and ignores late result',
    () async {
      final firstResponse = Completer<http.Response>();
      final submitted = <String>[];
      final cancelled = <String>[];
      final api = HandwritingApi(
        'http://localhost:5006',
        client: MockClient((request) async {
          if (request.url.path == '/api/generate_handwriting') {
            final id =
                request.headers['X-Panache-Task-Id'] ??
                request.headers['x-panache-task-id'];
            expect(
              id,
              matches(
                RegExp(
                  r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
                ),
              ),
            );
            submitted.add(id!);
            if (submitted.length == 1) return firstResponse.future;
            return http.Response(jsonEncode({'task_id': id}), 200);
          }
          final id = request.url.pathSegments[3];
          if (request.url.path.endsWith('/cancel')) {
            cancelled.add(id);
            return http.Response('{"task_status":"cancelled"}', 200);
          }
          if (request.url.path.endsWith('/result')) {
            return http.Response.bytes([2], 200);
          }
          return http.Response(
            jsonEncode({
              'task_status': cancelled.contains(id) ? 'cancelled' : 'completed',
            }),
            200,
          );
        }),
      );
      api.configureCapabilities({
        'capabilities': {'task_cancellation': true, 'task_submission_id': true},
      });
      final w = Workspace(api: api)..text = 'draft';
      w.settings.font = 'test.ttf';
      final old = w.generate();
      await Future<void>.delayed(Duration.zero);
      expect(submitted, hasLength(1));
      await w.cancel();
      expect(cancelled, [submitted.first]);
      expect(w.busy, isFalse);
      expect(await w.generate(), isTrue);
      expect(submitted.toSet(), hasLength(2));
      firstResponse.completeError(TimeoutException('response lost'));
      expect(await old, isFalse);
      expect(w.pages.single, [2]);
      expect(w.error, isEmpty);
      w.dispose();
    },
  );

  test(
    'lost submit response automatically cancels; HTTP 404 never confirms exit',
    () async {
      var allowCancel = false;
      var stopCalls = 0;
      final api = HandwritingApi(
        'http://localhost:5006',
        client: MockClient((request) async {
          if (request.url.path == '/api/generate_handwriting') {
            throw http.ClientException('response lost');
          }
          if (request.url.path.endsWith('/cancel')) {
            stopCalls++;
            return http.Response(
              allowCancel
                  ? '{"task_status":"cancelled"}'
                  : '{"message":"unknown endpoint"}',
              allowCancel ? 200 : 404,
            );
          }
          return http.Response('{"task_status":"cancelled"}', 200);
        }),
      );
      api.configureCapabilities({
        'capabilities': {'task_cancellation': true, 'task_submission_id': true},
      });
      final w = Workspace(api: api)..text = 'keep my draft';
      w.settings.font = 'test.ttf';
      expect(await w.generate(), isFalse);
      expect(stopCalls, 1);
      expect(w.busy, isTrue);
      expect(w.phase, 'cancelling');
      expect(w.error, 'unknown endpoint');
      expect(await w.generate(), isFalse);
      allowCancel = true;
      await w.cancel();
      expect(stopCalls, 2);
      expect(w.busy, isFalse);
      expect(w.phase, 'cancelled');
      expect(w.text, 'keep my draft');
      w.dispose();
    },
  );

  test(
    'HTTP cancellation requires capability and waits for actual terminal state',
    () async {
      var polls = 0;
      var posted = false;
      final api = HandwritingApi(
        'http://localhost:5006',
        accessToken: 'token',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer token');
          if (request.url.path.endsWith('/cancel')) {
            expect(request.method, 'POST');
            posted = true;
            return http.Response('{"task_status":"cancelling"}', 200);
          }
          polls++;
          return http.Response(
            jsonEncode({'task_status': polls < 3 ? 'cancelling' : 'cancelled'}),
            200,
          );
        }),
      );
      expect(api.supportsCancel, isFalse);
      api.configureCapabilities({'version': 'old-python'});
      expect(api.supportsCancel, isFalse);
      await expectLater(api.cancelTask('task'), throwsUnsupportedError);
      expect(posted, isFalse);
      api.configureCapabilities({
        'capabilities': {'task_cancellation': true},
      });
      expect(api.supportsCancel, isTrue);
      await api.cancelTask('task');
      expect(posted, isTrue);
      expect(polls, 3);
      api.close();
    },
  );

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
      api: HandwritingApi('http://localhost:5006', client: client),
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
  test('访问令牌覆盖提交、查询与结果下载', () async {
    final seen = <String>[];
    final api = HandwritingApi(
      'http://localhost:5006',
      accessToken: 'test-token',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-token');
        seen.add(request.url.path);
        return http.Response(
          '{"task_id":"abc","task_status":"completed"}',
          200,
        );
      }),
    );
    addTearDown(api.close);
    await api.submit({'text': '正文'}, {});
    await api.status('abc');
    await api.result('abc');
    expect(seen.length, 3);
  });
  test('取消状态终止轮询并显示任务错误', () async {
    var polls = 0;
    final w = Workspace(
      api: HandwritingApi(
        'http://localhost:5006',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response('{"task_id":"abc"}', 200);
          }
          polls++;
          return http.Response(
            '{"task_status":"cancelled","error_message":"cancelled"}',
            200,
          );
        }),
      ),
    );
    addTearDown(w.dispose);
    w.text = '正文';
    w.settings.font = 'test.ttf';
    await w.generate();
    expect(polls, 1);
    expect(w.busy, isFalse);
    expect(w.error, 'cancelled');
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
      api: HandwritingApi('http://localhost:5006', client: client),
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
