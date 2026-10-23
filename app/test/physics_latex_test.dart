import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/physics_latex.dart';

void main() {
  final Object? parsed = jsonDecode(
    File('test/fixtures/physics_latex.json').readAsStringSync(),
  );
  final cases = parsed! as List<Object?>;
  for (final item in cases) {
    final entry = item! as Map<String, Object?>;
    final source = entry['source']! as String;
    final expected = entry['expected']! as String;
    test('physics normalizer: ${entry['name']}', () {
      expect(normalizePhysicsLatex(source), expected);
      expect(normalizePhysicsLatex(expected), expected);
    });
  }

  test('physics bounds keep deeply nested and oversized input unchanged', () {
    for (final source in [
      '${List.filled(18, r'\abs{').join()}x${List.filled(18, '}').join()}',
      r'\dv{' + List.filled(4097, 'x').join() + r'}{t}',
      List.filled(32769, ' ').join() + r'\dv{x}',
    ]) {
      expect(normalizePhysicsLatex(source), source);
    }
  });

  test('unsupported derivatives prevent partial formula mutation', () {
    const source = r'\abs{x}+\pdv{\norm{u}}{x}{y}';
    expect(normalizePhysicsLatex(source), source);
  });

  test('large sequences preserve every bounded derivative', () {
    final source = List.filled(2000, r'\dv{x}+').join();
    final expected = List.filled(
      2000,
      r'\frac{\mathrm{d}}{\mathrm{d}{x}}+',
    ).join();
    expect(normalizePhysicsLatex(source), expected);
  });
}
