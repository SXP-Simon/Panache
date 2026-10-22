import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/math_segments.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  test('数学范围与货币、代码、路径和混合正文共享边界', () {
    final samples = [
      (r'Buy $5 and $10; $x^2$.', 'Buy \$5 and \$10; x².'),
      (r'Hello  \frac{a}{b}  world.', 'Hello  (a)/(b)  world.'),
      (r'Use \frac in prose.', r'Use \frac in prose.'),
      (r'C:\new\alpha.txt and $x_1$', r'C:\new\alpha.txt and x₁'),
      (r'路径：C:\new\alpha.txt；$x_1$', r'路径：C:\new\alpha.txt；x₁'),
      (
        r'网站：www.example.org/\alpha/x^2 $x_1$',
        r'网站：www.example.org/\alpha/x^2 x₁',
      ),
      (
        r'https://a.test/\alpha?q=$x^2$ and $x_1$',
        r'https://a.test/\alpha?q=$x^2$ and x₁',
      ),
      (r'`$x^2$` and $x^3$', r'`$x^2$` and x³'),
      (
        r'![图](data:image/png;base64,YQ==) $x^2$',
        '![图](data:image/png;base64,YQ==) x²',
      ),
    ];
    for (final (input, expected) in samples) {
      expect(convertLatex(input), expected, reason: input);
    }
  });
  test('罕见分式不泄漏私用区，无法映射的上下标保留结构', () {
    expect(
      convertLatex(r'$\frac{4}{3}+\frac{1}{9}+\frac{1}{10}$'),
      '(4)/(3)+(1)/(9)+(1)/(10)',
    );
    expect(convertLatex(r'$x^{ab}+x_{AB}+\sqrt[5]{x}$'), 'x^(ab)+x_(AB)+⁵√(x)');
    expect(
      convertLatex(r'$\vec{AB}+\hat{ab}+\underline{xy}$'),
      '(AB)⃗+(ab)̂+(xy)̲',
    );
  });
  test('所有重音保持整个基底而非逐字附着', () {
    final accents = {
      'bar': '\u0304',
      'overline': '\u0304',
      'hat': '\u0302',
      'widehat': '\u0302',
      'vec': '\u20d7',
      'dot': '\u0307',
      'ddot': '\u0308',
      'tilde': '\u0303',
      'widetilde': '\u0303',
      'breve': '\u0306',
      'acute': '\u0301',
      'grave': '\u0300',
      'check': '\u030c',
      'underline': '\u0332',
    };
    for (final entry in accents.entries) {
      expect(
        convertLatex('\$\\${entry.key}{AB}\$'),
        '(AB)${entry.value}',
        reason: entry.key,
      );
    }
  });
  test('未知节点和超限公式完整回退，后续合法公式继续转换', () {
    for (final source in [
      r'$\cancel{x}$',
      r'$\mathcal{abc}$',
      r'$\unknown{x}$',
      r'\[x+1',
      '\$${'x' * 16001}\$',
    ]) {
      expect(convertLatex(source), source);
    }
    expect(convertLatex(r'$\unknown{x}$ then $x^2$'), r'$\unknown{x}$ then x²');
  });
  test('Markdown 清洗保护比较式、脚标、竖线和未闭合公式', () {
    final examples = [
      (r'**Proof** $a<b>c$ and $x_i*y_j$.', r'Proof $a<b>c$ and $x_i*y_j$.'),
      (
        '| 式 | 值 |\n|---|---|\n|\$a\\mid b\$|\$x_1\$|',
        '1. 式: \$a\\mid b\$ (值: \$x_1\$)',
      ),
      (r'# 标题 $\unknown{x_y}$', r'标题 $\unknown{x_y}$'),
      (r'正文 \[a<b>c_x', r'正文 \[a<b>c_x'),
      (r'[项目](https://example.org/a_b/$x$/c)', '项目'),
      ('\uE100HW0\uE101 **正文** \$x_1\$', '\uE100HW0\uE101 正文 \$x_1\$'),
    ];
    for (final (input, expected) in examples) {
      expect(cleanMarkdown(input, tableMode: 'list'), expected, reason: input);
    }
  });
  test('长正文扫描保持线性预算并保留公式位置', () {
    final prose = 'ordinary prose ' * 10000;
    final input = '$prose\$x^2\$';
    final watch = Stopwatch()..start();
    final segments = scanMathSegments(input);
    expect(segments.where((s) => s.math).single.start, prose.length);
    expect(convertLatex(input), '${prose}x²');
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
