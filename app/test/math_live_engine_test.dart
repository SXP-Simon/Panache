import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/desktop_backend.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  const executable = String.fromEnvironment('DESKTOP_BACKEND_EXECUTABLE');
  test(
    'LaTeX 经 Dart 转换和真实 Rust 引擎生成窄页、网格与 PDF/ZIP',
    () async {
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp('math-engine-');
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
        w.settings.values.addAll({
          'width': '420',
          'height': '420',
          'font_size': '40',
          'line_spacing': '46',
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
        w.settings.fullPreview = true;
        final markdown = cleanMarkdown(
          '| 名称 | 概率 |\n'
          '| --- | --- |\n'
          r'| 甲\|乙 | $\frac8{15}$ |'
          '\n'
          r'| `a ; b` | $\frac13$ |',
          tableMode: 'latex',
        );
        w.text = convertLatex(
          r'公式 $x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}$'
          '\n'
          r'$\frac{1}{1+\frac{1}{1+\frac{1}{2}}}$'
          '\n'
          r'$a_{n+1}^{2}+\overrightarrow{AB}+\underline{xy}$'
          '\n'
          r'$\sqrt[12]{\frac{x+1}{x-1}}$'
          '\n'
          r'\[\begin{array}{c|cccc}X&0&1&2&3\\\hline P&\frac8{15}&\frac4{15}&\frac2{15}&\frac1{15}\end{array}\]'
          '\n'
          r'\[\boxed{\begin{array}{c|ccc}Y&1&2&3\\\hline P&\frac13&\frac13&\frac13\end{array}}\]'
          '\n---\n'
          r'$\frac{a+b+c+d+e+f+g+h+i+j+k+l+m+n}{x+y}$'
          '\n$markdown',
        );
        expect(w.text, isNot(contains(r'\begin')));
        expect(w.text, contains('⟦ X | 0  1  2  3 ; ── ; P |'));
        expect(w.text, contains('⟦ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ⟧'));
        expect(w.text, contains('"甲|乙"'));
        expect(w.text, contains('"a ; b"'));
        for (final grid in [false, true]) {
          w.settings.values['grid_layout'] = '$grid';
          w.settings.underlined = grid;
          await w.generate();
          expect(w.error, isEmpty, reason: 'grid=$grid');
          expect(w.pages.length, greaterThanOrEqualTo(2));
          for (final png in w.pages) {
            const output = String.fromEnvironment('MATH_RENDER_OUTPUT');
            if (output.isNotEmpty) {
              final destination = Directory(output);
              await destination.create(recursive: true);
              await File(
                '${destination.path}/math-grid-$grid-page-${w.pages.indexOf(png) + 1}.png',
              ).writeAsBytes(png);
            }
            expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
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
            expect(
              ink,
              greaterThan(100),
              reason: 'PNG must contain actual ink',
            );
            frame.image.dispose();
            codec.dispose();
          }
        }
        for (final pdf in [true, false]) {
          await w.generate(preview: false, pdf: pdf);
          expect(w.error, isEmpty);
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
    timeout: const Timeout(Duration(minutes: 3)),
    skip: executable.isEmpty
        ? '通过 DESKTOP_BACKEND_EXECUTABLE 指定真实 Rust 服务启用'
        : false,
  );
}
