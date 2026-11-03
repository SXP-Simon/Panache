import 'package:flutter_test/flutter_test.dart';

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
}
