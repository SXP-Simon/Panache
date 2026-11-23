import 'physics_latex.dart';
import 'siunitx_latex.dart';

String normalizeCourseLatex(String source) {
  source = normalizePhysicsLatex(source);
  final out = StringBuffer();
  var cursor = 0;
  while (cursor < source.length) {
    if (source[cursor] != r'\') {
      out.write(source[cursor++]);
      continue;
    }
    final command = RegExp(r'^\\([A-Za-z]+|.)')
        .firstMatch(source.substring(cursor));
    if (command == null) {
      out.write(source[cursor++]);
      continue;
    }
    final name = command[1]!;
    final end = cursor + command[0]!.length;
    final first = _argument(source, end);
    if (first == null) {
      out.write(command[0]);
      cursor = end;
      continue;
    }
    var consumed = first.end;
    final String? replacement;
    switch (name) {
      case 'text' || 'textrm' || 'textbf' || 'textit' || 'texttt' || 'verb':
        replacement = null;
      case 'ce':
        replacement = _chemicalFormula(first.body);
      case 'num':
        replacement = normalizeSiNumber(first.body);
      case 'si' || 'unit':
        replacement = normalizeSiUnit(first.body);
      case 'SI' || 'qty':
        final second = _argument(source, first.end);
        consumed = second?.end ?? first.end;
        replacement = second == null
            ? null
            : normalizeSiQuantity(first.body, second.body);
      default:
        out.write(command[0]);
        cursor = end;
        continue;
    }
    out.write(replacement ?? source.substring(cursor, consumed));
    cursor = consumed;
  }
  return out.toString();
}

({String body, int end})? _argument(String source, int start) {
  while (start < source.length && RegExp(r'\s').hasMatch(source[start])) {
    start++;
  }
  if (start >= source.length || source[start] != '{') return null;
  var depth = 1;
  for (var i = start + 1; i < source.length; i++) {
    if (source[i] == r'\') {
      i++;
      continue;
    }
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return (body: source.substring(start + 1, i), end: i + 1);
    }
  }
  return null;
}

String calligraphicCapitals(String value) {
  if (!RegExp(r'^[A-Z]+$').hasMatch(value)) {
    throw const FormatException('Unsupported calligraphic symbol');
  }
  const legacy = {
    'B': 'ℬ',
    'E': 'ℰ',
    'F': 'ℱ',
    'H': 'ℋ',
    'I': 'ℐ',
    'L': 'ℒ',
    'M': 'ℳ',
    'R': 'ℛ',
  };
  return value
      .split('')
      .map(
        (letter) =>
            legacy[letter] ??
            String.fromCharCode(0x1d49c + letter.codeUnitAt(0) - 65),
      )
      .join();
}

// A bounded mhchem subset. Bare counts remain subscripts; charge magnitude uses ^.
String? _chemicalSpecies(String source) {
  var value = source.trim(), suffix = '';
  final gas = RegExp(r'\s+([v^])$').firstMatch(value);
  if (gas != null) {
    suffix = gas[1] == 'v' ? r'\downarrow' : r'\uparrow';
    value = value.substring(0, gas.start).trim();
  }
  final state = RegExp(r'\((aq|s|l|g)\)$').firstMatch(value);
  if (state != null) {
    suffix = '\\mathrm{${state[0]}}$suffix';
    value = value.substring(0, state.start);
  }
  var charge = '';
  final ion = RegExp(r'(?:\^(?:\{(\d{0,3}[+-])\}|(\d{0,3}[+-]))|([+-]))$')
      .firstMatch(value);
  if (ion != null) {
    charge = '^{${ion[1] ?? ion[2] ?? ion[3]}}';
    value = value.substring(0, ion.start);
  }
  final coefficient = RegExp(r'^(\d+\/\d+|\d+(?:\.\d+)?)\s*').firstMatch(value);
  var result = coefficient?[1] ?? '';
  if (result.contains('/')) {
    final parts = result.split('/');
    if (!RegExp(r'[1-9]').hasMatch(parts[1])) return null;
    result = '\\frac{${parts[0]}}{${parts[1]}}\\,';
  }
  if (coefficient != null) value = value.substring(coefficient.end);
  final stack = <String>[];
  var atoms = 0, previous = false;
  for (var cursor = 0; cursor < value.length;) {
    final rest = value.substring(cursor);
    final element = RegExp(r'^(?:[A-Z][a-z]?|e)').firstMatch(rest);
    if (element != null) {
      result += element[0]!;
      atoms++;
      previous = true;
      cursor += element.end;
      continue;
    }
    final count = RegExp(r'^\d+').firstMatch(rest);
    if (count != null && previous) {
      if (count[0]!.length > 3) return null;
      result += '_{${count[0]}}';
      previous = true;
      cursor += count.end;
      continue;
    }
    final char = value[cursor];
    if (char == '(' || char == '[') {
      if (stack.length >= 8) return null;
      stack.add(char);
      result += char;
      previous = false;
    } else if (char == ')' || char == ']') {
      if (!previous ||
          stack.isEmpty ||
          stack.removeLast() != (char == ')' ? '(' : '[')) {
        return null;
      }
      result += char;
      previous = true;
    } else {
      return null;
    }
    cursor++;
  }
  if (atoms == 0 || stack.isNotEmpty) return null;
  return '\\mathrm{$result$charge}$suffix';
}

String? _chemicalFormula(String source) {
  if (source.length > 4096 || source.trim().isEmpty) return null;
  const arrows = {
    '->': r'\rightarrow',
    '<-': r'\leftarrow',
    '<->': r'\leftrightarrow',
    '<=>': r'\rightleftharpoons',
  };
  final delimiter = RegExp(r'\s*(<=>|<->|->|<-)\s*|\s+(\+)\s+');
  final parts = <String>[];
  var cursor = 0;
  final value = source.trim();
  for (final match in delimiter.allMatches(value)) {
    parts.add(value.substring(cursor, match.start));
    parts.add(match[1] ?? match[2]!);
    cursor = match.end;
  }
  parts.add(value.substring(cursor));
  if (parts.length > 127) return null;
  final result = <String>[];
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (index.isOdd) {
      final op = part == '+' ? '+' : arrows[part];
      if (op == null) return null;
      result.add(op);
    } else {
      final pieces = RegExp(r'^\d+\.\d+\s*[A-Z]').hasMatch(part)
          ? [part]
          : part.split(RegExp(r'\s*[*.·]\s*'));
      final converted = <String>[];
      for (final piece in pieces) {
        final formula = _chemicalSpecies(piece);
        if (formula == null) return null;
        converted.add(formula);
      }
      result.add(converted.join(r'\cdot '));
    }
  }
  return result.join(' ');
}
