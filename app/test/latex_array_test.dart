import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/utils/text_tools.dart';

void main() {
  const distributions = {
    r'\begin{array}{c|cccc}X&0&1&2&3\\ \hline P&\frac8{15}&\frac4{15}&\frac2{15}&\frac1{15}\end{array}':
        '[ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ]',
    r'\boxed{\begin{array}{c|ccc}Y&1&2&3\\ \hline P&\frac13&\frac13&\frac13\end{array}}':
        '[ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ]',
  };
  for (final entry in distributions.entries) {
    test('分布律保留行列与分隔规则：${entry.key}', () {
      final source = '于是，\\(X\\) 的分布律为\n\\[\n${entry.key}\n\\]';
      final expected = '于是，X 的分布律为\n${entry.value}';
      expect(convertLatex(cleanMarkdown(source)), expected);
      expect(cleanMarkdown(convertLatex(source)), expected);
      expect(convertLatex(source), expected);
      expect(convertLatex(entry.key), entry.value);
      expect(convertLatex(entry.value), entry.value);
    });
  }
  test('分数允许省略参数花括号', () {
    expect(convertLatex(r'$\frac13+\frac8{15}+\frac{1}3$'), '⅓+(8)/(15)+⅓');
  });
  test('增广矩阵、首尾规则和普通矩阵', () {
    expect(
      convertLatex(
        r'$\begin{array}{|cc|c|}\hline1&2&3\\4&5&6\\\hline\end{array}$',
      ),
      '[ ── ; | 1  2 | 3 | ; | 4  5 | 6 | ; ── ]',
    );
    expect(
      convertLatex(r'$\begin{pmatrix}1&2\\3&4\end{pmatrix}$'),
      '( 1  2 ; 3  4 )',
    );
    expect(
      convertLatex(r'$\begin{vmatrix}1&2\\3&4\end{vmatrix}$'),
      '| 1  2 ; 3  4 |',
    );
    expect(
      convertLatex(r'$\begin{array}{cc}1&\\&2\end{array}$'),
      '[ 1   ;   2 ]',
    );
  });
  test('非法或不完整公式整体保留', () {
    for (final source in [
      r'\[\begin{array}{c|cc}X&0&1\\P&\frac13&\frac23\end{matrix}\]',
      r'\[\begin{array}{cc}1&\frac1\end{array}\]',
      r'\[\boxed{\begin{array}{cc}1&2\\3&4\end{array}\]',
      r'\boxed{\begin{array}{cc}1&2\\3&4\end{array}',
      r'\[\begin{array}{cc}1&\mystery{2}\end{array}\]',
    ]) {
      expect(convertLatex(source), source);
      expect(convertLatex(cleanMarkdown(source)), source);
    }
  });
  test('代码和 Markdown 清洗保护数组源码', () {
    const source = r'\begin{array}{c|c}X&1\\\hline P&\frac13\end{array}';
    expect(convertLatex('`$source`'), '`$source`');
    expect(
      cleanMarkdown('**分布律**\n\\[\n$source\n\\]'),
      '分布律\n\\[\n$source\n\\]',
    );
  });
  test('不静默丢弃第三方 AST 无法表示的重复分隔线', () {
    for (final source in [
      r'$\begin{array}{c||c}1&2\\3&4\end{array}$',
      r'$\begin{array}{c|c}\hline\hline1&2\end{array}$',
    ]) {
      expect(convertLatex(source), source);
    }
  });
  test('虚线分隔和 cases 条件保持可读', () {
    expect(
      convertLatex(r'$\begin{array}{c:c}1&2\\\hdashline3&4\end{array}$'),
      '[ 1 ┆ 2 ; ╌╌ ; 3 ┆ 4 ]',
    );
    expect(
      convertLatex(r'$f(x)=\begin{cases}x^2&x>0\\0&x\le0\end{cases}$'),
      'f(x)={ x²  x>0 ; 0  x≤0 }',
    );
  });
}
