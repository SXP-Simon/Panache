import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/prepare_text.dart';

void main() {
  final cases = jsonDecode(
    File('test/fixtures/automata-latex.json').readAsStringSync(),
  ) as List;
  for (final entry in cases) {
    test('prepare automata source: ${entry[0]}', () {
      for (final delimiters in [
        [r'$', r'$'],
        [r'$$', r'$$'],
        [r'\(', r'\)'],
        [r'\[', r'\]'],
      ]) {
        final formula = '${delimiters[0]}${entry[1]}${delimiters[1]}';
        final expected = entry[2] ?? formula;
        final actual = prepareHandwritingText('### 正规式\n\n---\n$formula');
        expect(actual, '正规式\n$expected');
        expect(prepareHandwritingText(actual), actual);
      }
    });
  }
  test('literal code survives both cleanup stages', () {
    const code =
        'int *p;\n\n---\nx^2 + y_1;\n'
        r'\frac12 $x^2$ **literal**';
    expect(prepareHandwritingText('```cpp\n$code\n```'), code);
    expect(prepareHandwritingText(r'代码 `$x^2$`；公式 $x^2$'), '代码 \$x^2\$；公式 x²');
    expect(prepareHandwritingText('``x^2 ` *p``'), 'x^2 ` *p');
  });
  test('Markdown tables become handwriting grids with literal code cells', () {
    final actual = prepareHandwritingText(
      '| **变量** | 值 |\n| --- | --- |\n| `x^2` | \$x^2\$ |',
    );
    expect(actual, contains('⟦'));
    expect(actual, contains('x^2'));
    expect(actual, contains('²'));
    expect(actual, isNot(contains(r'\begin')));
    expect(prepareHandwritingText(actual), actual);
  });
  test('diagram and image sources remain usable', () {
    const circuit =
        r'\begin{circuitikz}\draw (0,0) to[R=$R_1$] (2,0);\end{circuitikz}';
    expect(prepareHandwritingText('**电路**\n$circuit'), '电路\n$circuit');
    expect(prepareHandwritingText('![插图 1|50]\n\n\$x^2\$'), '![插图 1|50]\nx²');
  });
}
