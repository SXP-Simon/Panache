import 'dart:convert' show jsonEncode;
import 'dart:ui' show FontStyle;

import 'package:flutter_math_fork/ast.dart';

import 'course_latex.dart';

const _superSource = '0123456789+-=()nixykm';
const _superTarget = '⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣʸᵏᵐ';
const _subSource = '0123456789+-=()aehijklmnoprstuvxy';
const _subTarget = '₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵧ';
String _script(String value, bool sup) {
  if (sup && value == '∘') return '°';
  if (sup && RegExp(r'^[′″‴⁗]+$').hasMatch(value)) return value;
  final source = sup ? _superSource : _subSource;
  final target = sup ? _superTarget : _subTarget;
  final chars = value.runes.map(String.fromCharCode).toList();
  return chars.isNotEmpty && chars.every(source.contains)
      ? chars.map((c) => target[source.indexOf(c)]).join()
      : '${sup ? '^' : '_'}($value)';
}

const _fractions = {
  '1/2': '½',
  '1/3': '⅓',
  '2/3': '⅔',
  '1/4': '¼',
  '3/4': '¾',
  '1/5': '⅕',
  '2/5': '⅖',
  '3/5': '⅗',
  '4/5': '⅘',
  '1/6': '⅙',
  '5/6': '⅚',
  '1/8': '⅛',
  '3/8': '⅜',
  '5/8': '⅝',
  '7/8': '⅞',
};
String _blackboard(String s) => s.runes.map((r) {
  final legacy = {
    'C': 'ℂ',
    'H': 'ℍ',
    'N': 'ℕ',
    'P': 'ℙ',
    'Q': 'ℚ',
    'R': 'ℝ',
    'Z': 'ℤ',
  };
  final c = String.fromCharCode(r);
  if (legacy.containsKey(c)) return legacy[c]!;
  if (r >= 65 && r <= 90) return String.fromCharCode(0x1d538 + r - 65);
  // The internal AMS fallback supplies capitals. Unsupported styled lowercase
  // and digits retain source rather than becoming unavailable Unicode glyphs.
  throw const FormatException('Unsupported blackboard symbol');
}).join();
String _symbol(String s) =>
    const {
      '−': '-',
      '∣': '|',
      '∥': '||',
      '…': '...',
      '⋯': '···',
      '∼': '~',
      '∗': '*',
      '⋅': '·',
      '⟹': '⇒',
      '⟸': '⇐',
      '⟺': '⇔',
      '⟶': '→',
      '⟵': '←',
      '⟷': '↔',
      '⪯': '≼',
      '⪰': '≽',
    }[s] ??
    s;
String _group(String s) {
  if (s.runes.length <= 1) return s;
  const pairs = {'(': ')', '[': ']', '{': '}', '⟨': '⟩'};
  if (pairs.containsKey(s[0])) {
    final stack = <String>[];
    for (var i = 0; i < s.length; i++) {
      if (pairs.containsKey(s[i])) {
        stack.add(pairs[s[i]]!);
      } else if (pairs.containsValue(s[i])) {
        if (stack.isEmpty || stack.removeLast() != s[i]) return '($s)';
        if (stack.isEmpty) return i == s.length - 1 ? s : '($s)';
      }
    }
  }
  return '($s)';
}

bool _uprightLabel(GreenNode? node, String text) {
  if (node is EquationRowNode && node.children.length == 1) {
    return _uprightLabel(node.children.single, text);
  }
  if (node is! StyleNode || !RegExp(r'^[A-Za-z]+$').hasMatch(text)) {
    return false;
  }
  final font = node.optionsDiff.mathFontOptions;
  // Upright labels and element symbols must not gain literal parentheses:
  // SO₄ is chemically different from (SO)₄. Expressions still need grouping.
  return font?.fontFamily == 'Main' && font?.fontShape == FontStyle.normal;
}

// Conversion uses the same public AST as the preview widget. Unknown semantic
// nodes fail the whole formula instead of silently deleting mathematical data.
String renderLatexNode(
  GreenNode? n, [
  int depth = 0,
  String mode = 'standalone',
]) {
  if (depth > 64) throw const FormatException('Math nesting limit');
  String child(GreenNode? v, [String? m]) =>
      renderLatexNode(v, depth + 1, m ?? mode);
  String scripts(GreenNode? sub, GreenNode? sup) =>
      '${sub == null ? '' : _script(child(sub), false)}${sup == null ? '' : _script(child(sup), true)}';
  if (n == null) return '';
  if (n is SymbolNode) return _symbol(n.symbol);
  if (n is EquationRowNode) return n.children.map(child).join();
  if (n is StyleNode) return _styled(n, child);
  if (n is FracNode) {
    if (n.barSize?.value == 0) {
      throw const FormatException('Unwrapped binomial');
    }
    final a = child(n.numerator).trim(), b = child(n.denominator).trim();
    return _fractions['$a/$b'] ?? '($a)/($b)';
  }
  if (n is SqrtNode) {
    final index = n.index == null ? '' : _script(child(n.index), true);
    if (index.startsWith('^')) {
      throw const FormatException('Unsupported root index');
    }
    return '$index√(${child(n.base)})';
  }
  if (n is MultiscriptsNode) return _multiscript(n, child);
  if (n is NaryOperatorNode) {
    return '${_symbol(n.operator)}${scripts(n.lowerLimit, n.upperLimit)}${child(n.naryand)}';
  }
  if (n is FunctionNode) {
    final name = child(n.functionName), argument = child(n.argument);
    final first = n.argument.children.firstOrNull;
    final space =
        argument.isEmpty ||
            (first is! FracNode && RegExp(r'^[\s([{]').hasMatch(argument))
        ? ''
        : ' ';
    return '$name$space$argument';
  }
  if (n is AccentNode) return _accent(n, child);
  if (n is AccentUnderNode) {
    if (n.label != '¯' && n.label != '⏟') {
      throw const FormatException('Unsupported under accent');
    }
    final base = child(n.base);
    return n.label == '⏟' ? base : '${_group(base)}\u0332';
  }
  if (n is OverNode) {
    return '${_group(child(n.base))}${_script(child(n.above), true)}';
  }
  if (n is UnderNode) {
    final base = child(n.base);
    return '${base == 'lim' ? base : _group(base)}${_script(child(n.below), false)}';
  }
  if (n is StretchyOpNode) {
    return '${_symbol(n.symbol)}${scripts(n.below, n.above)}';
  }
  if (n is LeftRightNode) return _delimited(n, child);
  if (n is MatrixNode) return _matrix(n, mode, child);
  if (n is EquationArrayNode) return _equationArray(n, mode, child);
  if (n is EnclosureNode) {
    if (n.notation.isNotEmpty) {
      throw const FormatException('Mathematical strike enclosure');
    }
    return child(n.base);
  }
  if (n is SpaceNode) {
    if (n.alignerOrSpacer || n.width.value <= 0) return '';
    if (n.fill) throw const FormatException('Rule');
    return mode == 'cases' ? '  ' : ' ';
  }
  throw FormatException('Unsupported ${n.runtimeType}');
}

typedef _Child = String Function(GreenNode?, [String?]);

String _styled(StyleNode n, _Child child) {
  final body = n.children.map(child).join();
  final family = n.optionsDiff.mathFontOptions?.fontFamily;
  if (family == 'AMS') return _blackboard(body);
  if (family == 'Caligraphic') return calligraphicCapitals(body);
  if (family != null &&
      !{'Main', 'Math', 'SansSerif', 'Typewriter'}.contains(family)) {
    throw const FormatException('Unsupported math font');
  }
  return body;
}

String _multiscript(MultiscriptsNode n, _Child child) {
  if (n.presub != null || n.presup != null) {
    throw const FormatException('Prescripts');
  }
  final base = child(n.base);
  final ungrouped =
      _uprightLabel(n.base, base) ||
      RegExp(r'^(?:lim|max|min|det|sin|cos|tan|log|ln|[|]+)$').hasMatch(base);
  return '${ungrouped ? base : _group(base)}${n.sub == null ? '' : _script(child(n.sub), false)}${n.sup == null ? '' : _script(child(n.sup), true)}';
}

String _accent(AccentNode n, _Child child) {
  final mark = const {
    '¯': '\u0304',
    '^': '\u0302',
    '→': '\u20d7',
    '˙': '\u0307',
    '¨': '\u0308',
    '~': '\u0303',
    '˘': '\u0306',
    '´': '\u0301',
    '`': '\u0300',
    'ˇ': '\u030c',
    '⏞': '',
    '⏟': '',
  }[n.label];
  if (mark == null) throw FormatException('Unsupported accent ${n.label}');
  final base = child(n.base);
  return mark.isEmpty ? base : '${_group(base)}$mark';
}

String _delimited(LeftRightNode n, _Child child) {
  final left = _symbol(n.leftDelim ?? ''), right = _symbol(n.rightDelim ?? '');
  final cases = left == '{' && right.isEmpty;
  final single = n.body.length == 1 && n.body.first.children.length == 1
      ? n.body.first.children.first
      : null;
  if (left == '(' &&
      right == ')' &&
      single is FracNode &&
      single.barSize?.value == 0) {
    return 'C(${child(single.numerator)}, ${child(single.denominator)})';
  }
  if (single is MatrixNode || single is EquationArrayNode) {
    final kind = const {
      '()': 'pmatrix',
      '[]': 'bmatrix',
      '{}': 'Bmatrix',
      '||': 'vmatrix',
      '||||': 'Vmatrix',
      '{': 'cases',
    }['$left$right'];
    if (kind != null) return child(single, kind);
  }
  final body = StringBuffer();
  for (var i = 0; i < n.body.length; i++) {
    if (i > 0) body.write(_symbol(n.middle[i - 1] ?? ''));
    body.write(child(n.body[i], cases ? 'cases' : 'matrix'));
  }
  return '$left$body${cases ? ' }' : right}';
}

bool _needsCellQuotes(String value) =>
    value.isEmpty ||
    RegExp(r'[;|┆⟦⟧"\\]').hasMatch(value) ||
    value.contains('  ');

String _matrixCell(String value, String mode) {
  if (!(mode == 'standalone' || mode.endsWith('matrix') || mode == 'cases')) {
    return value;
  }
  final reserved =
      RegExp(r'^\s*(?:matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|cases):')
          .hasMatch(value) ||
      value.trim() == '──' ||
      value.trim() == '╌╌';
  return reserved || _needsCellQuotes(value) ? jsonEncode(value) : value;
}

String _matrix(MatrixNode n, String mode, _Child child) {
  if (n.body.isEmpty ||
      n.body.length > 32 ||
      n.body.any((row) => row.isEmpty || row.length > 32)) {
    throw const FormatException('Matrix dimensions exceed renderer limits');
  }
  final ruled =
      n.vLines.any((v) => v != MatrixSeparatorStyle.none) ||
      n.hLines.any((v) => v != MatrixSeparatorStyle.none);
  String rule(MatrixSeparatorStyle style, bool horizontal) => switch (style) {
    MatrixSeparatorStyle.none => '',
    MatrixSeparatorStyle.solid => horizontal ? '──' : '|',
    MatrixSeparatorStyle.dashed => horizontal ? '╌╌' : '┆',
  };
  final lines = <String>[];
  for (var row = 0; row <= n.body.length; row++) {
    final horizontal = rule(n.hLines[row], true);
    if (horizontal.isNotEmpty) lines.add(horizontal);
    if (row == n.body.length) break;
    final cells = StringBuffer();
    for (var col = 0; col <= n.body[row].length; col++) {
      final vertical = rule(n.vLines[col], false);
      if (vertical.isNotEmpty) {
        if (col > 0) cells.write(' ');
        cells.write(vertical);
      }
      if (col == n.body[row].length) break;
      if (col > 0 || vertical.isNotEmpty) {
        cells.write(vertical.isEmpty ? '  ' : ' ');
      }
      final value = child(n.body[row][col]);
      cells.write(_matrixCell(value, mode));
    }
    lines.add(cells.toString());
  }
  final rows = lines.join(' ; ');
  if (mode == 'standalone') return ruled ? '⟦ $rows ⟧' : '⟦ matrix: $rows ⟧';
  if (mode.endsWith('matrix') || mode == 'cases') return '⟦ $mode: $rows ⟧';
  return ' $rows ';
}

String _equationArray(EquationArrayNode n, String mode, _Child child) {
  if (mode == 'cases' && (n.body.isEmpty || n.body.length > 32)) {
    throw const FormatException('Cases dimensions exceed renderer limits');
  }
  if (n.hlines.any((v) => v != MatrixSeparatorStyle.none)) {
    throw const FormatException('Equation rules');
  }
  final rows = n.body.map(
    (row) => mode == 'cases'
        ? _casesRow(row.children, child)
        : _alignedRow(row.children, child),
  );
  return mode == 'cases' ? '⟦ cases: ${rows.join(' ; ')} ⟧' : rows.join('\n');
}

String _casesRow(List<GreenNode?> items, _Child child) {
  final cells = <String>[];
  var cell = StringBuffer();
  var inside = false;
  for (final item in items) {
    if (item is SpaceNode && item.alignerOrSpacer) {
      if (inside) {
        cells.add(cell.toString());
        cell = StringBuffer();
      }
      inside = !inside;
    } else if (inside) {
      cell.write(child(item));
    }
  }
  if (inside) throw const FormatException('Incomplete cases column');
  if (cells.length != 2) {
    throw const FormatException('Cases need two columns');
  }
  return cells
      .map((value) => _needsCellQuotes(value) ? jsonEncode(value) : value)
      .join('  ');
}

String _alignedRow(List<GreenNode?> items, _Child child) {
  var columns = 0;
  final out = StringBuffer();
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is SpaceNode && item.alignerOrSpacer) {
      columns++;
      if (columns.isEven && i + 1 < items.length) out.write('  ');
    } else {
      out.write(child(item));
    }
  }
  return out.toString();
}
