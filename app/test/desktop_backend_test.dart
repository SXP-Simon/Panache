import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/desktop_backend.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import 'support/desktop_backend_executable.dart';

void main() {
  test('missing bundled executable fails without leaving a process', () async {
    final backend = DesktopBackend();
    await expectLater(
      backend.start(executable: '/missing/handwriting-server'),
      throwsA(isA<ProcessException>()),
    );
    await backend.stop();
  });

  const executable = String.fromEnvironment('DESKTOP_BACKEND_EXECUTABLE');
  test(
    'bundled process uses random port, token, local workspace and graceful exit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'handwriting-sidecar-',
      );
      final backend = DesktopBackend();
      try {
        final binary = await prepareBackendExecutable(executable, directory);
        final api = await backend.start(
          executable: binary,
          dataDirectory: directory.path,
        );
        expect(Uri.parse(api.base).host, '127.0.0.1');
        expect(Uri.parse(api.base).port, isNot(5006));
        expect(api.accessToken, isNotEmpty);
        final unauthenticated = await http.get(api.uri('/api/fonts_info'));
        expect(unauthenticated.statusCode, 401);
        SharedPreferences.setMockInitialValues({
          'flutter.api': 'http://127.0.0.1:1',
        });
        final workspace = Workspace(api: api, managedBackend: true);
        await workspace.initialize();
        expect(workspace.connected, isTrue);
        const expectedVersion = String.fromEnvironment('EXPECTED_APP_VERSION');
        if (expectedVersion.isNotEmpty) {
          expect(workspace.version, expectedVersion);
        }
        expect(workspace.api, same(api));
        await workspace.setBase('http://127.0.0.1:1');
        expect(workspace.api, same(api));
        workspace.text = '客户端离线生成测试';
        workspace.settings.values['width'] = '800';
        workspace.settings.values['height'] = '600';
        await workspace.generate();
        expect(workspace.error, isEmpty);
        expect(workspace.pages, isNotEmpty);
        workspace.dispose();
        await backend.stop();
        expect(await backend.exited, 0);
        await backend.stop();
        final restarted = await backend.start(
          executable: binary,
          dataDirectory: directory.path,
        );
        expect(restarted.accessToken, isNot(api.accessToken));
        Process.killPid(backend.pid!, ProcessSignal.sigkill);
        expect(await backend.exited, isNot(0));
        restarted.close();
        await backend.stop();
        final blocked = await File('${directory.path}/blocked')
            .writeAsString('not a directory');
        await expectLater(
          backend.start(executable: binary, dataDirectory: blocked.path),
          throwsStateError,
        );
        final recovered = await backend.start(
          executable: binary,
          dataDirectory: directory.path,
        );
        expect(await recovered.getJson('/api/fonts_info'), isNotEmpty);
        recovered.close();
        await backend.stop();
        expect(await backend.exited, 0);
      } finally {
        await backend.stop();
        await directory.delete(recursive: true);
      }
    },
    skip: executable.isEmpty
        ? 'Set DESKTOP_BACKEND_EXECUTABLE to a bundled Rust binary'
        : false,
  );
}
