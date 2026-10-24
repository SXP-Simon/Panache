import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  final cases = jsonDecode(
    File('test/fixtures/automata-latex.json').readAsStringSync(),
  ) as List;
  for (final entry in cases) {
    test('automata conversion and cleanup: ${entry[0]}', () {
      for (final delimiters in [
        [r'$', r'$'],
        [r'$$', r'$$'],
        [r'\(', r'\)'],
        [r'\[', r'\]'],
      ]) {
        final formula = '${delimiters[0]}${entry[1]}${delimiters[1]}';
        final expected = entry[2] ?? formula;
        expect(convertLatex(formula), expected);
        expect(convertLatex(cleanMarkdown(formula)), expected);
        expect(cleanMarkdown(convertLatex(formula)), expected);
        expect(cleanMarkdown(cleanMarkdown(convertLatex(formula))), expected);
        expect(convertLatex('`$formula`'), '`$formula`');
      }
    });
  }
  test(
    'script stars survive Markdown emphasis removal without affecting code',
    () {
      for (final source in [
        '(01)^(*) (10)^(*)',
        'a^*b^*',
        'a^{*} b^{*}',
        'x_(*) y_(*)',
        'x_* y_*',
      ]) {
        expect(cleanMarkdown(source), source);
        expect(cleanMarkdown('`$source`'), source);
        expect(cleanMarkdown('```text\n$source\n```'), source);
      }
      expect(cleanMarkdown('**闭包**：(01)^(*)，*说明*'), '闭包：(01)^(*)，说明');
    },
  );
}
