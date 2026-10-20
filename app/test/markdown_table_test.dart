import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/text_tools.dart';
import 'package:handwriting_app/utils/latex.dart';

void main() {
  test('默认保留二维网格和数学，重复清洗不变', () {
    const input = r'''| X | 0 | 1 |
| :--- | ---: | :---: |
| P | $\frac8{15}$ | \(\frac7{15}\) |''';
    final cleaned = cleanMarkdown(input);
    expect(cleaned, contains(r'\begin{array}{|c|c|c|}'));
    expect(cleaned, contains(r'\text{P} & \frac8{15} & \frac7{15}'));
    expect(RegExp(r'\\hline').allMatches(cleaned).length, 3);
    expect(cleanMarkdown(cleaned), cleaned);
    expect(convertLatex(cleaned), contains('⟦'));
    expect(cleanMarkdown(convertLatex(cleaned)), convertLatex(cleaned));
    final reversed = convertLatex(cleanMarkdown(convertLatex(input)));
    expect(reversed, contains('⟦'));
    expect(reversed, contains('(8)/(15)'));
    expect(reversed, isNot(contains(r'\begin')));
  });
  test('支持无外框线和缺少单元格，保留空格子', () {
    final cleaned = cleanMarkdown('科目 | 成绩 | 备注\n--- | --- | ---\n数学 | 98');
    expect(cleaned, contains(r'\text{数学} & \text{98} & '));
    expect(cleaned, contains(r'\begin{array}{|c|c|c|}'));
  });
  test('文字逐字安全转义，code和转义竖线不增加列', () {
    final cleaned = cleanMarkdown(r'''| 项目 | 内容 |
| --- | --- |
| `a|b` | 50% & {x}_# $ ^ ~ \ |''');
    expect(cleaned, contains(r'\begin{array}{|c|c|}'));
    expect(cleaned, contains(r'\text{a|b}'));
    for (final symbol in [
      r'50\%',
      r'\&',
      r'\{x\}\_\#',
      r'\$',
      r'\textasciicircum{}',
      r'\textasciitilde{}',
      r'\textbackslash{}',
    ]) {
      expect(cleaned, contains(symbol));
    }
    final escaped = cleanMarkdown(r'''a | b
--- | ---
x\|y | z''');
    expect(escaped, contains(r'\text{x|y}'));
  });
  test('数学绝对值的竖线不能拆列', () {
    final cleaned = cleanMarkdown(r'''X | P
--- | ---
$|x|$ | \(a|b\)''');
    expect(cleaned, contains(r'|x| & a|b'));
  });
  test('额外数据列和没有数据行的表保持原文', () {
    const ragged = '| a | b |\n| --- | --- |\n| 1 | 2 | 3 |';
    expect(cleanMarkdown(ragged), ragged);
    const headerOnly = '| a | b |\n| --- | --- |';
    expect(cleanMarkdown(headerOnly), headerOnly);
  });
  test('代码围栏里的表格仅去掉围栏，不进行表格转换', () {
    const body = '| a | b |\n| --- | --- |\n| 1 | 2 |';
    expect(cleanMarkdown('```text\n$body\n```'), body);
  });
  test('超行列和转义展开后的超长表格保留原文', () {
    for (final source in [
      'a | b\n--- | ---\n${List.filled(32, 'x | y').join('\n')}',
      '${List.filled(33, 'a').join(' | ')}\n${List.filled(33, '---').join(' | ')}\n${List.filled(33, 'x').join(' | ')}',
      'a | b\n--- | ---\n${'%' * 9000} | x',
    ]) {
      expect(cleanMarkdown(source), source);
    }
  });
  test('代码里的美元符号为文字，空格子保留而不是伪造破折号', () {
    final source = '| a | b |\n| --- | --- |\n| `\$x\$` | |';
    final result = cleanMarkdown(source);
    expect(result, contains(r'\text{\$x\$} & '));
    expect(result, isNot(contains(r'\text{-}')));
  });
  test('文字管道和分号通过引用单元格完整进入手写表格', () {
    const source = r'''| 项目 | 内容 |
| --- | --- |
| `a|b` | a ; b |
| 中文 | $\frac13$ |''';
    final result = convertLatex(cleanMarkdown(source));
    expect(result, contains('⟦'));
    expect(result, contains('"a|b"'));
    expect(result, contains('"a ; b"'));
    expect(result, contains('中文'));
    expect(result, contains('⅓'));
    expect(cleanMarkdown(result), result);
  });
  test('旧清单模式仍可显式选择，非表格管道不推测为表', () {
    expect(
      cleanMarkdown('| a | b |\n| --- | --- |\n| 1 | 2 |', tableMode: 'list'),
      '1. a: 1 (b: 2)',
    );
    expect(cleanMarkdown('a | b\n普通文本'), 'a | b\n普通文本');
  });
}
