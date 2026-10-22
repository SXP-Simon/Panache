import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  test('混合正文中的成对定界、括号幂和求值上下限整体转写', () {
    final cases = <String, String>{
      r'精确值：\left. \frac{1}{3}x^3 \right\vert{}_{-1}^{1} = \frac{2}{3}':
          '精确值：⅓x³|₋₁¹ = ⅔',
      r'右边：\frac{1}{2}\left[ (\frac{1}{2}-\frac{1}{2\sqrt{3}})^3 + (\frac{1}{2}+\frac{1}{2\sqrt{3}})^3 \right]':
          '右边：½[(½-(1)/(2√(3)))³+(½+(1)/(2√(3)))³]',
      r'展开：2 \times \left( (\frac{1}{2})^3 + 3 \times \frac{1}{2} \times (\frac{1}{2\sqrt{3}})^2 \right)':
          '展开：2 × ((½)³+3×½×((1)/(2√(3)))²)',
      r"导数 f'(x) = 3x^2，abc3x^2 原样": "导数 f'(x) = 3x²，abc3x^2 原样",
      r'代入：(-1)^2 + 8(0)^2 + 3(1)^2': '代入：(-1)² + 8(0)² + 3(1)²',
      r'嵌套：\left[\left(x^2+1\right)^3\right]': '嵌套：[(x²+1)³]',
    };
    for (final entry in cases.entries) {
      expect(convertLatex(entry.key), entry.value, reason: entry.key);
      expect(convertLatex(cleanMarkdown(entry.key)), entry.value);
    }
  });
  test('裸公式与定界公式一致，清洗和转换均保持幂与嵌套语义', () {
    final formulas = [
      r'\left.\frac{x^3}{3}\right|_{-1}^{1}',
      r'\left\langle x_1,x_2\right\rangle',
      r'\left\|\left(x_1^2+x_2^2\right)\right\|',
      r'\left\{x^2\right\}',
      r'\left[a_b+c_d\right]',
      r'\left(x+1\right)^3+\left[x-1\right]^2',
      r'(\frac{a}{b}+\sqrt{x})^{n+1}',
      r'(-1)^{2}+8(0)^2+3(1)^2',
      r'\left. F(x) \right\vert{}_{a}^{b}',
    ];
    for (final formula in formulas) {
      final expected = convertLatex('\$$formula\$');
      expect(expected, isNot(contains(r'\left')), reason: formula);
      expect(expected, isNot(contains(r'\right')), reason: formula);
      expect(convertLatex('公式：$formula，完成'), '公式：$expected，完成');
      final markdown = '标题\n  * 公式：$formula\n    续行';
      final cleaned = cleanMarkdown(markdown);
      expect(cleanMarkdown(cleaned), cleaned);
      expect(convertLatex(cleaned), '标题\n公式：$expected\n续行');
      expect(cleanMarkdown(convertLatex(markdown)), '标题\n公式：$expected\n续行');
    }
    expect(convertLatex(r'代码：`\left(x^2\right)`'), r'代码：`\left(x^2\right)`');
    expect(convertLatex(r'未知：\unknown{x_1}'), r'未知：\unknown{x_1}');
  });
  test('清洗条目和引用缩进而保留独立正文及代码', () {
    expect(
      cleanMarkdown('标题\n * 条目\n   继续说明\n\n  普通缩进\n  >   引用\n > > - 嵌套条目'),
      '标题\n条目\n继续说明\n  普通缩进\n引用\n嵌套条目',
    );
    expect(cleanMarkdown('正文\n```text\n   - literal\n```'), '正文\n   - literal');
    expect(convertLatex(r'原样：\left(x^2'), r'原样：\left(x²');
  });
}
