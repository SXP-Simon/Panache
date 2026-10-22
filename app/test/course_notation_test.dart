import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/course_latex.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  const cases = {
    r'$R=\SI{4.7}{\kilo\ohm}$': 'R=4.7 kΩ',
    r'$C=\SI{2.2e-6}{\farad}$': 'C=2.2×10⁻⁶ F',
    r'$a=\SI{9.81}{\metre\per\second\squared}$': 'a=9.81 m/s²',
    r'$f=\SI{50}{\hertz}$': 'f=50 Hz',
    r'$T=\SI{25}{\degreeCelsius}$': 'T=25 °C',
    r'$t=\SI{.5}{\micro\second}$': 't=.5 μs',
    r'$\num{6.02e23}$': '6.02×10²³',
    r'$\si{\second\tothe{-1}}$': 's⁻¹',
    r'$\si{\kilogram\metre\per\second\squared}$': 'kg m/s²',
    r'$\si{\joule\per\mole\per\kelvin}$': 'J/(mol K)',
    r'$\si{\pascal\per\second\henry}$': 'Pa H/s',
    r'$\si{\per\second}$': '1/s',
    r'$\mathcal{L}\{f(t)\}=F(s)$': 'ℒ{f(t)}=F(s)',
    r'$\mathcal{F}\{x(t)\}=X(\omega)$': 'ℱ{x(t)}=X(ω)',
    r'$\mathcal{P}(A)$': '𝒫(A)',
    r'$x[n]\xleftrightarrow{\mathcal{Z}}X(z)$': 'x[n]↔^(𝒵)X(z)',
    r'$\underline{U}=220\angle30^\circ$': 'U̲=220∠30°',
    r'$\sin^2 x+\cos^2 x=1$': 'sin² x+cos² x=1',
    r'$\det(A)=\operatorname{rank}A$': 'det(A)=rank A',
    r'$\operatorname{sinc}(x)=\frac{\sin\pi x}{\pi x}$':
        'sinc(x)=(sin πx)/(πx)',
    r'$\left(x+1\right)^2$': '(x+1)²',
    r'$\left(x+1\right)\left(x-1\right)^2$': '(x+1)(x-1)²',
    r'$\begin{cases}x^2&x\ge0\\-x&x<0\end{cases}$':
        '⟦ cases: x²  x≥0 ; -x  x<0 ⟧',
    r'$\begin{Vmatrix}a&b\\c&d\end{Vmatrix}$': '⟦ Vmatrix: a  b ; c  d ⟧',
    r'$\begin{bmatrix}x_1\\x_2\end{bmatrix}$': '⟦ bmatrix: x₁ ; x₂ ⟧',
  };
  for (final entry in cases.entries) {
    test('工程书写：${entry.key}', () {
      expect(convertLatex(entry.key), entry.value);
      expect(
        convertLatex(cleanMarkdown('**公式**\n${entry.key}')),
        '公式\n${entry.value}',
      );
      expect(convertLatex(entry.value), entry.value);
    });
  }
  test('不能推测单位选项、误差、physics qty 或电路图拓扑', () {
    for (final source in [
      r'$\SI[parse-numbers=false]{2}{\volt}$',
      r'$\num{1.23(4)}$',
      r'$\SI{9.81}{m.s^{-2}}$',
      r'$\si{\unknown}$',
      r'$\si{\metre\per}$',
      r'$\si{\per\per\second}$',
      r'$\qty(\frac{a}{b})$',
      r'$\mathcal{abc}$',
      r'\begin{circuitikz}\draw (0,0) to[R=$R_1$] (2,0);\end{circuitikz}',
      r'\begin{tikzpicture}\draw (0,0)--(1,1);\end{tikzpicture}',
    ]) {
      expect(convertLatex(source), source);
      expect(convertLatex(cleanMarkdown(source)), source);
    }
  });
  test('单位归一化不改转义反斜线与 text 字面内容', () {
    for (final source in [r'\\SI{2}{\volt}', r'\text{\SI{2}{\volt}}']) {
      expect(normalizeCourseLatex(source), source);
    }
  });
  test('表格文字不能伪装成矩阵协议，空格子显式占位', () {
    expect(
      convertLatex(
        r'$\begin{array}{c|c}\text{matrix: label}&1\\a&b\end{array}$',
      ),
      '⟦ "matrix: label" | 1 ; a | b ⟧',
    );
    expect(
      convertLatex(r'$\begin{pmatrix}1&\\&1\end{pmatrix}$'),
      '⟦ pmatrix: 1  "" ; ""  1 ⟧',
    );
  });
}
