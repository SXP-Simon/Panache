import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  const header = 'A | B\n--- | ---\n';

  test('数学中的代码跨过同名数学定界符，结尾竖线仍然分列', () {
    for (final row in [
      r'$a`$|`|b$ | z',
      r'\(a`\)|`|b\) | z',
      r'``a`|b`` | z',
    ]) {
      final cleaned = cleanMarkdown('$header$row');
      expect(cleaned, contains(r'\begin{array}{|c|c|}'), reason: row);
      expect(cleaned, contains(r' & \text{z}'), reason: row);
    }
  });

  test('未闭合的代码或数学定界符吞入行尾竖线', () {
    for (final row in [r'open ``a` | z', r'open $a | z', r'open \(a | z']) {
      expect(
        cleanMarkdown('$header$row'),
        isNot(contains(r'\begin{array}')),
        reason: row,
      );
    }
  });
}
