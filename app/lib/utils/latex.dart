import 'package:flutter_math_fork/tex.dart';

import 'course_latex.dart';
import 'latex_ast.dart';
import 'math_segments.dart';
import 'physics_latex.dart';

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
    // alignedat retains the declared column budget in the upstream AST parser.
    normalized = normalized.replaceAllMapped(
      RegExp(r'\\(begin|end)\{alignat\*?\}'),
      (m) => '\\${m[1]}{alignedat}',
    );
    // flutter_math_fork 0.7.4 incorrectly gives Vmatrix a single-bar delimiter.
    normalized = normalized
        .replaceAll(r'\begin{Vmatrix}', r'\left\Vert\begin{matrix}')
        .replaceAll(r'\end{Vmatrix}', r'\end{matrix}\right\Vert');
    final tree = TexParser(
      normalizeCourseLatex(normalized),
      const TexParserSettings(
        displayMode: true,
        throwOnError: true,
        maxExpand: 500,
        strict: Strict.ignore,
      ),
    ).parse();
    return renderLatexNode(tree);
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
    for (var i = 0; i < lines.length; i++)
      _bareLine(lines[i], hasNextLine: i < lines.length - 1),
  ].join('\n');
}

final _lineBreak = RegExp(r'\\\\[ \t]*(?:\[[^\]]*\])?[ \t]*$');

String _bareLine(String line, {required bool hasNextLine}) {
  if (!withinMathBudget(line)) return line;
  // Keep all physics arguments in view before the generic token scanner.
  if (RegExp(r'\\(?:dv|pdv|abs|norm)(?![A-Za-z])').hasMatch(line)) {
    final normalized = normalizePhysicsLatex(line);
    return normalized == line ? line : _bareText(normalized);
  }
  if (_lineBreak.hasMatch(line)) {
    final prefix = line.replaceFirst(_lineBreak, '');
    return '${_bareText(prefix)}${hasNextLine ? '' : '\n'}';
  }
  if (_isBare(line.trim())) {
    var converted = _formula(line.trim());
    if (converted == null) return line;
    if (hasNextLine && converted.endsWith('\n')) {
      converted = converted.substring(0, converted.length - 1);
    }
    return '${RegExp(r'^\s*').firstMatch(line)![0]}$converted${RegExp(r'\s*$').firstMatch(line)![0]}';
  }
  return _convertBareTokens(line);
}

final _bareCommand = RegExp(
  r'\\([a-zA-Z]+|[^a-zA-Z\n])|(?<![\w])(\d*[a-zA-Z]|[0-9])((?:[_^](?:\{[^{}]*\}|[a-zA-Z0-9]))+)|(\()',
);

int _commandArity(String name) {
  const two = {
    'frac',
    'dfrac',
    'tfrac',
    'binom',
    'dbinom',
    'tbinom',
    'overset',
    'underset',
    'SI',
    'qty',
  };
  const one = {
    'sqrt',
    'boxed',
    'fbox',
    'text',
    'mathrm',
    'mathbb',
    'mathcal',
    'mathfrak',
    'mathbf',
    'mathit',
    'mathsf',
    'mathtt',
    'operatorname',
    'bar',
    'overline',
    'underline',
    'hat',
    'widehat',
    'vec',
    'tilde',
    'widetilde',
    'dot',
    'ddot',
    'underbrace',
    'overbrace',
    'breve',
    'acute',
    'grave',
    'check',
    'ce',
    'si',
    'unit',
    'num',
  };
  if (two.contains(name)) return 2;
  return one.contains(name) ? 1 : 0;
}

int _scriptsEnd(String line, int end) {
  while (end < line.length && (line[end] == '_' || line[end] == '^')) {
    final after = _argumentEnd(line, end + 1);
    if (after == end + 1) break;
    end = after;
  }
  return end;
}

final _spaces = RegExp(r'\s*');
int _commandEnd(String line, int end, String name, int arity) {
  if (name == 'sqrt') {
    final next = _spaces.matchAsPrefix(line, end)!.end;
    if (next < line.length && line[next] == '[') end = _argumentEnd(line, next);
  }
  for (var i = 0; i < arity; i++) {
    final next = _spaces.matchAsPrefix(line, end)!.end;
    final after = _argumentEnd(line, next);
    if (after == next) return line.length;
    end = after;
  }
  while (end < line.length && line[end] == '{') {
    final after = _argumentEnd(line, end);
    if (after == end) break;
    end = after;
  }
  return _scriptsEnd(line, end);
}

String _convertBareTokens(String line) {
  var cursor = 0;
  final out = StringBuffer();
  while (cursor < line.length) {
    final match = _bareCommand.firstMatch(line.substring(cursor));
    if (match == null) break;
    final start = cursor + match.start;
    var end = cursor + match.end;
    out.write(line.substring(cursor, start));
    final name = match[1];
    if (name == r'\') {
      out.write('\n');
      cursor = end;
      continue;
    }
    if (match[4] != null) {
      final after = _argumentEnd(line, start);
      if (after > start &&
          after < line.length &&
          (line[after] == '^' || line[after] == '_')) {
        end = _scriptsEnd(line, after);
      }
    }
    if (name == 'left') {
      final paired = bareDelimiterEnd(line, start);
      if (paired > start) end = paired;
    }
    if (name != null) {
      final arity = _commandArity(name);
      if (arity > 0 &&
          RegExp(r'\s+[a-zA-Z]').matchAsPrefix(line, end) != null) {
        out.write(line.substring(start, end));
        cursor = end;
        continue;
      }
      end = _commandEnd(line, end, name, arity);
    }
    final raw = line.substring(start, end);
    out.write(_formula(raw) ?? raw);
    cursor = end;
  }
  out.write(line.substring(cursor));
  return out.toString();
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
