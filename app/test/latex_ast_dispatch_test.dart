import 'package:flutter_math_fork/tex.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex_ast.dart';

void main() {
  const settings = TexParserSettings(displayMode: true, throwOnError: true);

  test('每层子节点消耗一级嵌套预算', () {
    final row = TexParser('x', settings).parse();
    expect(renderLatexNode(row, 63), 'x');
    expect(
      () => renderLatexNode(row, 64),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Math nesting limit',
        ),
      ),
    );
  });

  test('根式内的空白沿用外层分段模式', () {
    final root = TexParser(r'\sqrt{a\quad b}', settings).parse();
    expect(renderLatexNode(root), '√(a b)');
    expect(renderLatexNode(root, 0, 'cases'), '√(a  b)');
  });

  test('无法写作上标的根指数保留原有错误', () {
    final root = TexParser(r'\sqrt[q]{x}', settings).parse();
    expect(
      () => renderLatexNode(root),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Unsupported root index',
        ),
      ),
    );
  });
}
