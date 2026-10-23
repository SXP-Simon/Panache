import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/course_latex.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  const cases = <String, String>{
    r'$\ce{2H2 + O2 -> 2H2O}$': '2H₂+O₂→2H₂O',
    r'$\ce{SO4^2- + Ba^2+ -> BaSO4 v}$': 'SO₄²⁻+Ba²⁺→BaSO₄↓',
    r'$\ce{N2 + 3H2 <=> 2NH3}$': 'N₂+3H₂⇌2NH₃',
    r'$\ce{(NH4)2SO4 -> 2NH4+ + SO4^2-}$': '(NH₄)₂SO₄→2NH₄⁺+SO₄²⁻',
    r'$\ce{Ag+ + Cl- -> AgCl v}$': 'Ag⁺+Cl⁻→AgCl↓',
    r'$\ce{CuSO4 * 5H2O}$': 'CuSO₄·5H₂O',
    r'$\qty{9.81}{\metre\per\second\squared}$': '9.81 m/s²',

    r'$R=\qty{4.7}{\kilo\ohm}$': "R=4.7 kΩ",
    r'$\unit{\joule\per\mole\per\kelvin}$': "J/(mol K)",
    r'$\ce{NH4+}$': "NH₄⁺",
    r'$\ce{Fe3+}$': "Fe₃⁺",
    r'$\ce{Fe^3+}$': "Fe³⁺",
    r'$\ce{SO4^2-}$': "SO₄²⁻",
    r'$\ce{Fe^{3+}}$': "Fe³⁺",
    r'$\ce{[Cu(NH3)4]^2+}$': "[Cu(NH₃)₄]²⁺",
    r'$\ce{Fe^3+ + e- -> Fe^2+}$': "Fe³⁺+e⁻→Fe²⁺",
    r'$\ce{Fe^{3+} + 3OH- -> Fe(OH)3 v}$': "Fe³⁺+3OH⁻→Fe(OH)₃↓",
    r'$\ce{CaCO3(s) -> CaO(s) + CO2 ^}$': "CaCO₃(s)→CaO(s)+CO₂↑",
    r'$\ce{H+(aq) + OH-(aq) -> H2O(l)}$': "H⁺(aq)+OH⁻(aq)→H₂O(l)",
    r'$\ce{CuSO4*5H2O}$': "CuSO₄·5H₂O",
    r'$\ce{CuSO4.5H2O}$': "CuSO₄·5H₂O",
    r'$\ce{0.5 O2}$': "0.5O₂",
    r'$\ce{1/2 O2}$': "½ O₂",
    r'$\ce{H2O <- H+ + OH-}$': "H₂O←H⁺+OH⁻",
    r'$\ce{A <-> B}$': "A↔B",
    r'离子 \ce{NH4+}。': "离子 NH₄⁺。",
    r'$\begin{alignat}{2}x+y&=3,&\qquad x-y&=1\\2x&=4,&x&=2\end{alignat}$':
        "x+y=3,   x-y=1\n2x=4,  x=2",
  };
  for (final entry in cases.entries) {
    test('化学和常用宏：${entry.key}', () {
      expect(convertLatex(entry.key), entry.value);
      expect(
        convertLatex(cleanMarkdown('**题目**\n${entry.key}')),
        '题目\n${entry.value}',
      );
    });
  }
  const unsupported = [
    r'$\ce{^{14}_{6}C}$',
    r'$\ce{Fe^{II}}$',
    r'$\ce{C6H5-CHO}$',
    r'$\ce{A=B}$',
    r'$\ce{A#B}$',
    r'$\ce{H2 ->[\Delta] H}$',
    r'$\ce{A <=>[H2O][OH-] B}$',
    r'$\ce{\unknown{formula}}$',
    r'$\ce{\SI{2}{\volt}}$',
    r'$\ce{H2 +}$',
    r'$\ce{+ H2}$',
    r'$\ce{H2 ->}$',
    r'$\ce{-> H2}$',
    r'$\ce{H2 + + O2}$',
    r'$\ce{H2 + O2 -> }$',
    r'$\ce{Mg(OH2}$',
    r'$\ce{Mg()2}$',
    r'$\ce{H9999}$',
    r'$\ce{H2 + cat -> H2}$',
    r'$\ce{H2 + O2? -> H2O}$',
    r'$\ce{H2 <--> H2}$',
    r'$\ce{H2 <=>> H2}$',
    r'$\ce{H2/CO2}$',
    r'$\ce{n H2O}$',
    r'$\ce{NO_x}$',
    r'$\qty[round-mode=places]{1.23}{\volt}$',
    r'$\unit{\unknown}$',
    r'$\begin{alignat}{1}a&=b&c&=d\end{alignat}$',
  ];
  for (final source in unsupported) {
    test('不丢失未知化学/宏语法：$source', () {
      expect(convertLatex(source), source);
      expect(convertLatex(cleanMarkdown(source)), source);
    });
  }
  test('化学长度预算和文字语境', () {
    final huge =
        r'\ce{'
        '${'H2O' * 1500}}';
    expect(normalizeCourseLatex(huge), huge);
    for (final source in [
      r'\text{Use \ce{NH4+} here}',
      r'\\ce{NH4+}',
      r'\ce{H2 ->[\SI{2}{\volt}] H2}',
    ]) {
      expect(normalizeCourseLatex(source), source);
    }
  });
}
