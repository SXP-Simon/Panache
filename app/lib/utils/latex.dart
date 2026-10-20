import 'dart:ui' show FontStyle;

import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/tex.dart';

import 'math_segments.dart';

const _superSource = '0123456789+-=()nixykm';
const _superTarget = '⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣʸᵏᵐ';
const _subSource = '0123456789+-=()aehijklmnoprstuvxy';
const _subTarget = '₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵧ';
String _script(String value, bool sup) {
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
String _group(String s) => s.runes.length > 1 ? '($s)' : s;

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
String _node(GreenNode? n, [int depth = 0, String mode = 'standalone']) {
  if (depth > 64) throw const FormatException('Math nesting limit');
  String child(GreenNode? v, [String? m]) => _node(v, depth + 1, m ?? mode);
  if (n == null) return '';
  if (n is SymbolNode) return _symbol(n.symbol);
  if (n is EquationRowNode) return n.children.map(child).join();
  if (n is StyleNode) {
    final body = n.children.map(child).join();
    final family = n.optionsDiff.mathFontOptions?.fontFamily;
    if (family == 'AMS') return _blackboard(body);
    if (family != null &&
        !{'Main', 'Math', 'SansSerif', 'Typewriter'}.contains(family)) {
      throw const FormatException('Unsupported math font');
    }
    return body;
  }
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
  if (n is MultiscriptsNode) {
    if (n.presub != null || n.presup != null) {
      throw const FormatException('Prescripts');
    }
    final base = child(n.base);
    final ungrouped =
        _uprightLabel(n.base, base) ||
        RegExp(r'^(?:lim|max|min|det|sin|cos|tan|log|ln|[|]+)$').hasMatch(base);
    return '${ungrouped ? base : _group(base)}${n.sub == null ? '' : _script(child(n.sub), false)}${n.sup == null ? '' : _script(child(n.sup), true)}';
  }
  if (n is NaryOperatorNode) {
    return '${_symbol(n.operator)}${n.lowerLimit == null ? '' : _script(child(n.lowerLimit), false)}${n.upperLimit == null ? '' : _script(child(n.upperLimit), true)}${child(n.naryand)}';
  }
  if (n is FunctionNode) return '${child(n.functionName)}${child(n.argument)}';
  if (n is AccentNode) {
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
    return '${child(n.base) == 'lim' ? 'lim' : _group(child(n.base))}${_script(child(n.below), false)}';
  }
  if (n is StretchyOpNode) {
    return '${_symbol(n.symbol)}${n.below == null ? '' : _script(child(n.below), false)}${n.above == null ? '' : _script(child(n.above), true)}';
  }
  if (n is LeftRightNode) {
    final left = _symbol(n.leftDelim ?? ''),
        right = _symbol(n.rightDelim ?? '');
    if (left == '(' &&
        right == ')' &&
        n.body.length == 1 &&
        n.body.first.children.length == 1) {
      final frac = n.body.first.children.first;
      if (frac is FracNode && frac.barSize?.value == 0) {
        return 'C(${child(frac.numerator)}, ${child(frac.denominator)})';
      }
    }
    final cases = left == '{' && right.isEmpty;
    final body = StringBuffer();
    for (var i = 0; i < n.body.length; i++) {
      if (i > 0) body.write(_symbol(n.middle[i - 1] ?? ''));
      body.write(child(n.body[i], cases ? 'cases' : 'matrix'));
    }
    return '$left$body${cases ? ' }' : right}';
  }
  if (n is MatrixNode) {
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
          if (cells.isNotEmpty) cells.write(' ');
          cells.write(vertical);
        }
        if (col == n.body[row].length) break;
        if (col > 0 || vertical.isNotEmpty) {
          cells.write(vertical.isEmpty ? '  ' : ' ');
        }
        cells.write(child(n.body[row][col]));
      }
      lines.add(cells.toString());
    }
    final rows = lines.join(mode == 'cases' ? '\n' : ' ; ');
    return mode == 'cases'
        ? '\n$rows'
        : mode == 'standalone'
        ? '[ $rows ]'
        : ' $rows ';
  }
  if (n is EquationArrayNode) {
    if (n.hlines.any((v) => v != MatrixSeparatorStyle.none)) {
      throw const FormatException('Equation rules');
    }
    final rows = n.body.map((row) {
      if (mode == 'cases') return child(row);
      var columns = 0;
      final out = StringBuffer();
      for (var i = 0; i < row.children.length; i++) {
        final item = row.children[i];
        if (item is SpaceNode && item.alignerOrSpacer) {
          columns++;
          if (columns.isEven && i + 1 < row.children.length) out.write('  ');
        } else {
          out.write(child(item));
        }
      }
      return out.toString();
    }).toList();
    return mode == 'cases' ? ' ${rows.join(' ; ')}' : rows.join('\n');
  }
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

String? _formula(String source) {
  if (!withinMathBudget(source)) return null;
  // The upstream AST retains only one separator per edge. Keep formulas with
  // repeated rules verbatim rather than silently losing an augmented group.
  if (RegExp(
        r'\\begin\{(?:d?array|subarray)\}\s*\{[^{}]*[|:][ \t]*[|:][^{}]*\}',
      ).hasMatch(source) ||
      RegExp(r'\\h(?:dash)?line\s*\\h(?:dash)?line').hasMatch(source)) {
    return null;
  }
  try {
    var normalized = source.replaceAllMapped(
      RegExp(r'\\(?:text|textrm|textbf|textit)\s*\{[^{}]*\}'),
      (m) => m[0]!.replaceAllMapped(RegExp(r'(\\.)|&'), (x) => x[1] ?? r'\&'),
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'\\(begin|end)\{(align\*?|gather\*?|gathered)\}'),
      (m) => '\\${m[1]}{aligned}',
    );
    final tree = TexParser(
      normalized,
      const TexParserSettings(
        displayMode: true,
        throwOnError: true,
        maxExpand: 500,
        strict: Strict.ignore,
      ),
    ).parse();
    return _node(tree);
  } on Object {
    return null;
  }
}

bool _isBare(String text) {
  if (!RegExp(r'[\\^_]').hasMatch(text)) return false;
  final rest = text
      .replaceAll(RegExp(r'\\(?:text|operatorname|mathrm)\s*\{[^{}]*\}'), '')
      .replaceAll(RegExp(r'\\[a-zA-Z]+|\\.'), '')
      .replaceAll(RegExp(r'\b(?:sin|cos|tan|log|ln|lim|max|min|det)\b'), '');
  return !RegExp(r'[a-zA-Z]{2,}').hasMatch(rest) &&
      rest.runes.every((r) => r <= 127);
}

int _argumentEnd(String text, int start) {
  if (start >= text.length) return start;
  var cursor = start;
  if (text[cursor] == '{' || text[cursor] == '[' || text[cursor] == '(') {
    final open = text[cursor],
        close = open == '{'
            ? '}'
            : open == '('
            ? ')'
            : ']';
    var depth = 1;
    while (++cursor < text.length && depth > 0) {
      if (text[cursor] == r'\') {
        cursor++;
        continue;
      }
      if (text[cursor] == open) depth++;
      if (text[cursor] == close) depth--;
    }
    return depth > 0 ? start : cursor;
  }
  final token = RegExp(r'^(?:\\[a-zA-Z]+|\\.|[^\s])')
      .firstMatch(text.substring(cursor));
  return token == null ? start : cursor + token[0]!.length;
}

String _bareText(String text) {
  final lines = text.split('\n');
  return [
    for (var li = 0; li < lines.length; li++)
      (() {
        final line = lines[li];
        if (!withinMathBudget(line)) return line;
        if (RegExp(r'\\\\[ \t]*(?:\[[^\]]*\])?[ \t]*$').hasMatch(line)) {
          final prefix = line.replaceFirst(
            RegExp(r'\\\\[ \t]*(?:\[[^\]]*\])?[ \t]*$'),
            '',
          );
          return '${_bareText(prefix)}${li < lines.length - 1 ? '' : '\n'}';
        }
        if (_isBare(line.trim())) {
          var converted = _formula(line.trim());
          if (converted == null) return line;
          if (li < lines.length - 1 && converted.endsWith('\n')) {
            converted = converted.substring(0, converted.length - 1);
          }
          return '${RegExp(r'^\s*').firstMatch(line)![0]}$converted${RegExp(r'\s*$').firstMatch(line)![0]}';
        }
        final command = RegExp(
          r'\\([a-zA-Z]+|[^a-zA-Z\n])|(?<![\w])(\d*[a-zA-Z]|[0-9])((?:[_^](?:\{[^{}]*\}|[a-zA-Z0-9]))+)|(\()',
        );
        var cursor = 0, search = 0;
        final out = StringBuffer();
        while (search < line.length) {
          final match = command.firstMatch(line.substring(search));
          if (match == null) break;
          final start = search + match.start;
          var end = search + match.end;
          final name = match[1];
          if (match[4] != null) {
            final after = _argumentEnd(line, start);
            if (after > start &&
                after < line.length &&
                (line[after] == '^' || line[after] == '_')) {
              end = after;
              while (end < line.length &&
                  (line[end] == '^' || line[end] == '_')) {
                final next = _argumentEnd(line, end + 1);
                if (next == end + 1) break;
                end = next;
              }
            }
          }
          if (name == 'left') {
            final pairedEnd = bareDelimiterEnd(line, start);
            if (pairedEnd > start) end = pairedEnd;
          }
          if (name != null) {
            if (name == r'\') {
              out.write('${line.substring(cursor, start)}\n');
              cursor = end;
              search = end;
              continue;
            }
            final arity =
                RegExp(
                  r'^(?:frac|dfrac|tfrac|binom|dbinom|tbinom|overset|underset)$',
                ).hasMatch(name)
                ? 2
                : RegExp(
                    r'^(?:sqrt|boxed|fbox|text|mathrm|mathbb|mathcal|mathfrak|mathbf|mathit|mathsf|mathtt|operatorname|bar|overline|underline|hat|widehat|vec|tilde|widetilde|dot|ddot|underbrace|overbrace|breve|acute|grave|check)$',
                  ).hasMatch(name)
                ? 1
                : 0;
            if (arity > 0 &&
                RegExp(r'^\s+[a-zA-Z]').hasMatch(line.substring(end))) {
              out.write(line.substring(cursor, end));
              cursor = end;
              search = end;
              continue;
            }
            if (name == 'sqrt') {
              final next =
                  end +
                  RegExp(r'^\s*').firstMatch(line.substring(end))![0]!.length;
              if (next < line.length && line[next] == '[') {
                end = _argumentEnd(line, next);
              }
            }
            for (var a = 0; a < arity; a++) {
              final next =
                  end +
                  RegExp(r'^\s*').firstMatch(line.substring(end))![0]!.length;
              final after = _argumentEnd(line, next);
              if (after == next) {
                end = line.length;
                break;
              }
              end = after;
            }
            while (end < line.length && line[end] == '{') {
              final after = _argumentEnd(line, end);
              if (after == end) break;
              end = after;
            }
            while (end < line.length &&
                (line[end] == '_' || line[end] == '^')) {
              final after = _argumentEnd(line, end + 1);
              if (after == end + 1) break;
              end = after;
            }
          }
          final raw = line.substring(start, end);
          out.write('${line.substring(cursor, start)}${_formula(raw) ?? raw}');
          cursor = end;
          search = end;
        }
        out.write(line.substring(cursor));
        return out.toString();
      })(),
  ].join('\n');
}

String convertLatex(String text) {
  final out = StringBuffer();
  var cursor = 0;
  for (final segment in scanMathSegments(text)) {
    out.write(_bareText(text.substring(cursor, segment.start)));
    final raw = text.substring(segment.start, segment.end);
    out.write(segment.math ? _formula(segment.body) ?? raw : raw);
    cursor = segment.end;
  }
  out.write(_bareText(text.substring(cursor)));
  return out.toString();
}
