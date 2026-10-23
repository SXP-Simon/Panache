import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';

void main() {
  const cases = <String, String>{
    r'\dv{y}{x}': "(dy)/(dx)",
    r'\dv[2]{y}{x}': "(d²y)/(dx²)",
    r'\dv{x}': "(d)/(dx)",
    r'\pdv[2]{T}{x}': "(∂²T)/(∂x²)",
    r'\abs{x-1}': "|x-1|",
    r'\norm{v}': "||v||",
  };
  for (final entry in cases.entries) {
    test('完整的裸宏和定界 physics：${entry.key}', () {
      expect(convertLatex(entry.key), entry.value);
      expect(convertLatex('\$${entry.key}\$'), entry.value);
      expect(convertLatex('结果 ${entry.key}，下一步。'), '结果 ${entry.value}，下一步。');
      expect(convertLatex('`${entry.key}`'), '`${entry.key}`');
    });
  }
  const unsupported = [
    r'\dv{f}{x}{y}',
    r'\dv{\frac{1}{x}}{x}{y}',
    r'\dv{x}(x^2)',
    r'\pdv{f}{x,y}',
    r'\dv*{f}{x}',
    r'\dv[100]{y}{x}',
    r'\abs*{x}',
    r'\norm[2]{v}',
  ];
  for (final source in unsupported) {
    test('不把不支持的 physics 参数截断：$source', () {
      expect(convertLatex(source), source);
      expect(convertLatex('\$$source\$'), '\$$source\$');
      expect(convertLatex('保留 $source。'), '保留 $source。');
    });
  }
}
