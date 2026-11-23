import 'package:flutter_test/flutter_test.dart';

import 'package:handwriting_app/utils/prepare_text.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  test('removes blank code lines and preserves indentation and operators', () {
    expect(
      cleanMarkdown(
        '```c\n\nvoid T() {\n    *p = a < b;\n   \n    return;\n}\n\n```',
      ),
      'void T() {\n    *p = a < b;\n    return;\n}',
    );
  });

  test('cleans emphasis across math boundaries but preserves literal code', () {
    final source = r'''| 名称 | 值 |
| --- | --- |
| **$E$** | **结果 $x$ 正确** |
| `**literal**` | $a*b$ |''';
    final result = cleanMarkdown(source);
    expect(result, isNot(contains(r'\text{**}')));
    expect(result, contains(r'\text{**literal**}'));
    expect(result, contains('a*b'));
    expect(cleanMarkdown(result), result);
  });

  test(
    'keeps literal markers in math, prose, and code at the paste boundary',
    () {
      const glyph = '\uE110CODE0\uE111';
      const equation = '\$\\text{$glyph / \uE110CODE17\uE111}\$';
      const source = 'Legend: `**ink**`\nFormula: $equation';
      const expected = 'Legend: **ink**\nFormula: $equation';
      expect(cleanMarkdown(source), expected);
      expect(prepareHandwritingText(source), expected);
      expect(
        cleanMarkdown('Printed: $glyph\n~~~text\n$glyph and `**raw**`\n~~~'),
        'Printed: $glyph\n$glyph and `**raw**`',
      );
    },
  );

  test('formatting and links can join literal marker fragments', () {
    // Exercise a matching index as well as a number that was never issued.
    const literal = '\uFDD0';
    const end = '\uE111';
    const source =
        '`**code**` ${literal}CO**D**E0$end '
        '${literal}CO[DE](guide.md)999$end '
        '$literal\uFDD1 $literal$literal';
    expect(
      cleanMarkdown(source),
      '**code** ${literal}CODE0$end ${literal}CODE999$end '
      '$literal\uFDD1 $literal$literal',
    );
  });

  test('table cells preserve literal markers alongside code and math', () {
    const glyph = '\uE130';
    const reserve = '\uFDD0';
    const source =
        '| Symbol | Value |\n| --- | --- |\n'
        '| ${glyph}CE**LL**0\uE131 and \$x\$ | `**ink**` / ${reserve}CE**LL**0\uE131 |';
    expect(
      cleanMarkdown(source),
      contains(
        '\\text{${glyph}CELL0\uE131 and }x & '
        '\\text{**ink**}\\text{ / ${reserve}CELL0\uE131}',
      ),
    );
  });

  test('an unmatched backtick run leaves later complete code spans intact', () {
    const source = 'Type ``` literally, then `**keep**` and ``a`b``.';
    expect(cleanMarkdown(source), 'Type ``` literally, then **keep** and a`b.');
  });
}
