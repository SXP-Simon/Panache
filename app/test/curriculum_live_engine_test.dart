import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/desktop_backend.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/utils/latex.dart';

import 'support/latex_curriculum_cases.dart';

void main() {
  const executable = String.fromEnvironment('DESKTOP_BACKEND_EXECUTABLE');
  test(
    'all curriculum formulas traverse Dart conversion and the real Rust engine',
    () async {
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp('curriculum-');
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
        w.settings.font = w.fonts.contains('云烟体.ttf')
            ? '云烟体.ttf'
            : w.fonts.first;
        w.settings.fullPreview = true;
        w.settings.values.addAll({
          'height': '1000',
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
        for (final course in latexCurriculumCases.entries) {
          // Long real-engine suites expose course progress in CI diagnostics.
          print('Rendering curriculum: ${course.key}');
          w.text = course.value
              .map((example) {
                final (name, source, expected) = example;
                final actual = convertLatex(source);
                expect(actual, expected, reason: '${course.key}: $name');
                return actual;
              })
              .join('\n');
          for (final (width, size, grid) in [
            (600, 24, false),
            (300, 40, false),
            (480, 32, true),
          ]) {
            printOnFailure(
              '${course.key}: width=$width, size=$size, grid=$grid',
            );
            w.settings.values.addAll({
              'grid_layout': '$grid',
              'width': '$width',
              'font_size': '$size',
              'line_spacing': '${size + 12}',
            });
            w.settings.underlined = grid;
            expect(
              await w.generate(),
              isTrue,
              reason: '${course.key}: ${w.error}',
            );
            expect(w.pages, isNotEmpty);
            for (final png in w.pages) {
              final codec = await ui.instantiateImageCodec(png);
              final image = (await codec.getNextFrame()).image;
              try {
                expect(image.width, width);
                expect(image.height, 1000);
                final pixels = (await image.toByteData())!;
                var ink = 0;
                for (
                  var offset = 0;
                  offset < pixels.lengthInBytes;
                  offset += 4
                ) {
                  if (pixels.getUint8(offset) < 100 &&
                      pixels.getUint8(offset + 1) < 100 &&
                      pixels.getUint8(offset + 2) < 100) {
                    ink++;
                  }
                }
                expect(
                  ink,
                  greaterThan(20),
                  reason: '${course.key}: blank page',
                );
              } finally {
                image.dispose();
                codec.dispose();
              }
            }
          }
        }
        // Export the same interdisciplinary text, including the last course.
        w.text = latexCurriculumCases.values
            .expand((entries) => entries)
            .map((example) => convertLatex(example.$2))
            .join('\n');
        for (final pdf in [true, false]) {
          expect(
            await w.generate(preview: false, pdf: pdf),
            isTrue,
            reason: w.error,
          );
          expect(
            latin1.decode(w.exportBytes!.take(pdf ? 5 : 2).toList()),
            pdf ? '%PDF-' : 'PK',
          );
        }
      } finally {
        workspace?.dispose();
        await backend.stop();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: executable.isEmpty
        ? 'Set DESKTOP_BACKEND_EXECUTABLE to enable the real Rust engine'
        : false,
  );
}
