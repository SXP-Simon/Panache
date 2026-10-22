import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/desktop_backend.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

// Record the multipart contract while sending every request to the real API.
// This catches edits or serialization between the editor and native engine.
class _RecordingApi extends HandwritingApi {
  _RecordingApi(HandwritingApi api)
    : super(api.base, client: api.client, accessToken: api.accessToken);
  final requests = <Map<String, String>>[];

  @override
  Future<String> submit(Map<String, String> fields, Map<String, Upload> files) {
    requests.add(Map.of(fields));
    expect(files, isEmpty);
    return super.submit(fields, files);
  }
}

void main() {
  const executable = String.fromEnvironment('DESKTOP_BACKEND_EXECUTABLE');
  test(
    'CircuiTikZ traverses editing tools, Workspace and real PNG/PDF/ZIP API',
    () async {
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp(
        'circuit-engine-',
      );
      final backend = DesktopBackend();
      Workspace? workspace;
      try {
        final api = _RecordingApi(
          await backend.start(
            executable: executable,
            dataDirectory: directory.path,
          ),
        );
        final w = workspace = Workspace(api: api, managedBackend: true);
        await w.connect();
        expect(w.connected, isTrue, reason: w.error);
        expect(w.fonts, isNotEmpty);
        w.settings.font = w.fonts.contains('霞鹜文楷.ttf')
            ? '霞鹜文楷.ttf'
            : w.fonts.first;
        w.settings.fullPreview = true;
        w.settings.underlined = false;
        w.settings.values.addAll({
          'height': '900',
          'font_size': '32',
          'line_spacing': '48',
          'left_margin': '24',
          'right_margin': '24',
          'top_margin': '24',
          'bottom_margin': '24',
          'font_size_sigma': '0',
          'line_spacing_sigma': '0',
          'word_spacing_sigma': '0',
          'perturb_x_sigma': '0',
          'perturb_y_sigma': '0',
          'perturb_theta_sigma': '0',
          'ink_depth_sigma': '0',
          'strikethrough_probability': '0',
        });
        final fixtures =
            (jsonDecode(
                  File(
                    '../crates/handwriting-core/tests/fixtures/circuitikz.json',
                  ).readAsStringSync(),
                ) as List<Object?>)
                .cast<Map<String, Object?>>()
                .where(
                  (fixture) => {
                    'rc-lowpass',
                    'parallel-current',
                    'named-relative',
                    'unsupported-opamp',
                  }.contains(fixture['id']),
                )
                .toList();
        expect(fixtures, hasLength(4));
        for (final fixture in fixtures) {
          final id = fixture['id']! as String;
          final source = fixture['source']! as String;
          w.text = convertLatex(cleanMarkdown('```latex\n$source\n```'));
          expect(w.text, source, reason: id);
          for (final width in [600, 320]) {
            w.settings.values['width'] = '$width';
            expect(await w.generate(), isTrue, reason: '$id: ${w.error}');
            expect(w.error, isEmpty);
            expect(w.taskId, isNotEmpty);
            expect(w.progress, 100);
            expect(api.requests.last['text'], source);
            expect(api.requests.last['preview'], 'true');
            expect(api.requests.last['full_preview'], 'true');
            expect(w.pages, isNotEmpty);
            if (fixture['valid'] == true) expect(w.pages, hasLength(1));
            for (var page = 0; page < w.pages.length; page++) {
              final png = w.pages[page];
              expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
              final codec = await ui.instantiateImageCodec(png);
              final image = (await codec.getNextFrame()).image;
              try {
                expect(image.width, width);
                expect(image.height, 900);
                final rgba = (await image.toByteData())!;
                var ink = 0, longestRun = 0;
                var minX = width, minY = image.height, maxX = 0, maxY = 0;
                for (var y = 0; y < image.height; y++) {
                  var run = 0;
                  for (var x = 0; x < image.width; x++) {
                    final offset = (y * image.width + x) * 4;
                    final dark =
                        rgba.getUint8(offset) < 100 &&
                        rgba.getUint8(offset + 1) < 100 &&
                        rgba.getUint8(offset + 2) < 100 &&
                        rgba.getUint8(offset + 3) > 200;
                    if (dark) {
                      ink++;
                      run++;
                      if (run > longestRun) longestRun = run;
                      if (x < minX) minX = x;
                      if (x > maxX) maxX = x;
                      if (y < minY) minY = y;
                      if (y > maxY) maxY = y;
                    } else {
                      run = 0;
                    }
                  }
                }
                expect(ink, greaterThan(100), reason: '$id: empty output');
                expect(minX, greaterThan(0), reason: '$id: left clipping');
                expect(minY, greaterThan(0), reason: '$id: top clipping');
                expect(
                  maxX,
                  lessThan(width - 1),
                  reason: '$id: right clipping',
                );
                expect(
                  maxY,
                  lessThan(image.height - 1),
                  reason: '$id: bottom clipping',
                );
                if (fixture['valid'] == true) {
                  // The supported circuits have long continuous wire strokes,
                  // rather than merely printing their source as handwriting.
                  expect(longestRun, greaterThan(35), reason: id);
                }
              } finally {
                image.dispose();
                codec.dispose();
              }
              const output = String.fromEnvironment('CIRCUIT_RENDER_OUTPUT');
              if (output.isNotEmpty) {
                final destination = Directory(output);
                await destination.create(recursive: true);
                await File(
                  '${destination.path}/flutter-$id-$width-${page + 1}.png',
                ).writeAsBytes(png);
              }
            }
          }
        }
        // Export supported circuit geometry through the same Workspace path.
        final source = fixtures.first['source']! as String;
        w.text = source;
        for (final pdf in [true, false]) {
          expect(
            await w.generate(preview: false, pdf: pdf),
            isTrue,
            reason: w.error,
          );
          expect(api.requests.last['text'], source);
          expect(api.requests.last['preview'], 'false');
          expect(api.requests.last['pdf_save'], '$pdf');
          expect(w.exportExtension, pdf ? 'pdf' : 'zip');
          expect(
            latin1.decode(w.exportBytes!.take(pdf ? 5 : 2).toList()),
            pdf ? '%PDF-' : 'PK',
          );
          expect(w.exportBytes!.length, greaterThan(100));
        }
      } finally {
        workspace?.dispose();
        await backend.stop();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: executable.isEmpty
        ? 'Set DESKTOP_BACKEND_EXECUTABLE to enable the real Rust circuit engine'
        : false,
  );
}
