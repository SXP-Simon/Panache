import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';

void main() {
  final cases =
      jsonDecode(File('test/fixtures/latex.json').readAsStringSync()) as List;
  for (final entry in cases) {
    test(
      '旧 LaTeX 样例：${entry[0]}',
      () => expect(convertLatex(entry[1] as String), entry[2]),
    );
  }
}
