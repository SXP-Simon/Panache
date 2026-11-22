@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/mcp_connection_native.dart';

void main() {
  Map<String, dynamic>? entry(
    String system,
    String app,
    Map<String, String> files,
  ) {
    final json = installedMcpConfig(
      system,
      app,
      fileExists: files.containsKey,
      readMarker: (path) => files[path]!,
    );
    return json == null ? null : jsonDecode(json)['mcpServers']['panache'];
  }

  test('Windows drive and UNC configurations keep paths as one argument', () {
    for (final root in [r'D:\中文 & AI 工作台', r'\\nas\tools\中文 & AI 工作台']) {
      final runtime = '$root\\Versions\\1.18.1-5';
      final app = '$runtime\\handwriting_app.exe';
      final backend = '$runtime\\backend\\panache-mcp.exe';
      final launcher = '$root\\handwriting_app.exe';
      final marker = '$root\\panache-install.json';
      final pointer = '$root\\active.json';
      final files = {
        backend: '',
        launcher: '',
        marker: '{"mcp_launcher":true}',
        pointer: '',
      };
      expect(entry('windows', app, files), {
        'command': launcher,
        'args': ['--mcp'],
      });
      for (final missing in [launcher, marker, pointer]) {
        expect(entry('windows', app, {...files}..remove(missing)), {
          'command': backend,
        });
      }
      for (final value in ['{}', '{']) {
        expect(entry('windows', app, {...files, marker: value}), {
          'command': backend,
        });
      }
      expect(entry('windows', app, {...files}..remove(backend)), isNull);
    }
  });

  test(
    'macOS bundles and Linux folders preserve Unicode, quotes and spaces',
    () {
      const mac = '/Applications/手写 "AI".app/Contents';
      const linux = "/home/user/手写 'AI' & 工具";
      for (final (system, app, server) in [
        ('macos', '$mac/MacOS/Panache', '$mac/Resources/backend/panache-mcp'),
        ('linux', '$linux/handwriting_app', '$linux/backend/panache-mcp'),
      ]) {
        expect(entry(system, app, {server: ''}), {'command': server});
        expect(entry(system, app, {}), isNull);
      }
    },
  );

  test('mobile platforms never inspect desktop files', () {
    for (final system in ['android', 'ios']) {
      expect(
        installedMcpConfig(
          system,
          '/app',
          fileExists: (_) => fail('desktop lookup'),
          readMarker: (_) => fail('desktop marker'),
        ),
        isNull,
      );
    }
  });
}
