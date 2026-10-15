import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';

import 'support/latex_curriculum_cases.dart';

/// Hand-authored curriculum examples. Expected values describe mathematical
/// meaning, including grouping, signs, indices, limits and reaction arrows.
/// They are intentionally independent of the converter's current output.
void main() {
  for (final course in latexCurriculumCases.entries) {
    group(course.key, () {
      for (final (name, source, expected) in course.value) {
        test(name, () {
          expect(convertLatex(source), expected, reason: source);
        });
      }
    });
  }

  group('不认识的领域命令必须整体保留', () {
    for (final source in [
      r'$\ce{SO4^2- + Ba^2+ -> BaSO4 v}$',
      r'$\pu{9.81 m/s^2}$',
      r'$\qty(\frac{a}{b})$',
      r'$\SI{9.81}{m.s^{-2}}$',
      r'$\mystery{x}+\alpha$',
      r'$\begin{tikzcd}A\arrow[r]&B\end{tikzcd}$',
    ]) {
      test(source, () => expect(convertLatex(source), source));
    }
  });

  test('教材正文中的多学科公式独立转换且不改代码片段', () {
    expect(
      convertLatex(r'能量 $E=mc^2$；水 $\mathrm{H}_2\mathrm{O}$；代码 `$x^2$`。'),
      r'能量 E=mc²；水 H₂O；代码 `$x^2$`。',
    );
  });
}
