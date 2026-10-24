import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/desktop_backend.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  const executable = String.fromEnvironment('DESKTOP_BACKEND_EXECUTABLE');
  test(
    'real HTTP engine cancels uploads and running tasks then regenerates',
    () async {
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp(
        'generation-stop-',
      );
      final backend = DesktopBackend();
      Workspace? workspace;
      try {
        final api = await backend.start(
          executable: executable,
          dataDirectory: directory.path,
        );
        final w = workspace = Workspace(api: api, managedBackend: true);
        await w.connect();
        expect(w.connected, isTrue, reason: w.error);
        expect(api.supportsCancel, isTrue);
        w.settings.font = '霞鹜文楷.ttf';
        w.settings.fullPreview = true;
        w.settings.values.addAll({
          'width': '1600',
          'height': '2200',
          'font_size': '70',
          'line_spacing': '120',
        });
        final prior = Uint8List.fromList([1]);
        w.pages = [prior];
        for (final waitForRenderer in [false, true]) {
          w.text = '停止任务测试'.padRight(20000, '字');
          final generation = w.generate();
          final id = w.taskId;
          expect(id, isNotEmpty);
          if (waitForRenderer) {
            for (var attempt = 0; attempt < 600; attempt++) {
              try {
                final status = await api.status(id);
                if (status['task_status'] == 'processing') break;
                expect(status['task_status'], 'pending');
              } on ApiException catch (error) {
                if (error.status != 404 || attempt > 500) rethrow;
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect((await api.status(id))['task_status'], 'processing');
          }
          await w.cancel();
          expect(await generation, isFalse);
          expect(w.busy, isFalse);
          expect((await api.status(id))['task_status'], 'cancelled');
          expect(w.pages.single, same(prior));
          expect(w.error, isEmpty);
          expect(await Directory('${directory.path}/results').list().length, 0);
        }
        w.text = '取消后重新生成';
        expect(await w.generate(), isTrue, reason: w.error);
        expect(w.pages.single.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      } finally {
        workspace?.dispose();
        await backend.stop();
        await directory.delete(recursive: true);
      }
    },
    skip: executable.isEmpty
        ? 'Set DESKTOP_BACKEND_EXECUTABLE for the real Rust sidecar'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
