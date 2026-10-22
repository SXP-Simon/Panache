import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/math_segments.dart';
import 'package:handwriting_app/utils/text_tools.dart';

import 'support/circuit_examples.dart';

void main() {
  final fixtures = (jsonDecode(
    File('../crates/handwriting-core/tests/fixtures/circuitikz.json')
        .readAsStringSync(),
  ) as List<Object?>).cast<Map<String, Object?>>();
  for (final fixture in fixtures) {
    test(
      '${fixture['id']}: shared engine fixture reaches preview unchanged',
      () {
        final source = fixture['source']! as String;
        expect(convertLatex(source), source);
        expect(cleanMarkdown(source), source);
        expect(convertLatex(cleanMarkdown(source)), source);
        expect(cleanMarkdown(convertLatex(source)), source);
        expect(convertLatex(cleanMarkdown('```latex\n$source\n```')), source);
      },
    );
  }
  for (final entry in circuitExamples.entries) {
    test('${entry.key}: editing tools preserve topology and math labels', () {
      final source = entry.value;
      final segment = scanMathSegments(source).single;
      expect(segment.math, isFalse);
      expect(segment.safeMathLiteral, isTrue);
      expect(segment.display, isTrue);
      expect(segment.body, source);
      expect(convertLatex(source), source);
      for (final mode in ['latex', 'list', 'aligned', 'raw_pipe', 'clean']) {
        expect(cleanMarkdown(source, tableMode: mode), source, reason: mode);
        expect(convertLatex(cleanMarkdown(source, tableMode: mode)), source);
        expect(cleanMarkdown(convertLatex(source), tableMode: mode), source);
      }
      expect(cleanMarkdown('```latex\n$source\n```'), source);
      expect(cleanMarkdown(cleanMarkdown('```tex\n$source\n```')), source);
      expect(convertLatex('**电路**\n$source\n\$x^2\$'), '**电路**\n$source\nx²');
      expect(
        convertLatex(cleanMarkdown('## 电路\n$source\n\n**结论** \$x^2\$')),
        '电路\n$source\n结论 x²',
      );
    });
  }
  test('comments cannot close the circuit and expose labels to conversion', () {
    const source = r'''\begin{circuitikz}
% \end{circuitikz} is an example, not a closing command.
\draw (0,0) to[R,l=$R_1$] (2,0); % $x^2$ and **literal**
\draw (2,0) -- (2,2); % \begin{array}{cc}
\end{circuitikz}''';
    expect(scanMathSegments(source).single.body, source);
    expect(convertLatex(source), source);
    expect(cleanMarkdown(source), source);
    expect(convertLatex('$source\n\$x^3\$'), '$source\nx³');
  });
  test(
    'unsupported, incomplete and oversized circuit source remains editable',
    () {
      for (final source in [
        r'\begin{circuitikz}\ctikzset{custom/.style={R}}\draw (0,0) to[custom] (2,0);\end{circuitikz}',
        r'\begin{circuitikz}\draw (0,0) to[R,l=$R_1$] (2,0);',
        r'\begin{circuitikz}\begin{scope}\draw (0,0)--(1,1);\end{scope}\end{circuitikz}',
        '\\begin{circuitikz}\n${'% source\n' * 3000}\\end{circuitikz}',
      ]) {
        expect(convertLatex(source), source);
        expect(cleanMarkdown(source), source);
      }
    },
  );
  test(
    'table-looking content inside an unsupported diagram is not promoted',
    () {
      const source = r'''\begin{circuitikz}
% This circuit uses a custom node unsupported by the renderer.
\node at (0,0) {a | b
--- | ---
x | y};
\end{circuitikz}''';
      expect(cleanMarkdown(source), source);
      expect(convertLatex(cleanMarkdown(source)), source);
    },
  );
}
