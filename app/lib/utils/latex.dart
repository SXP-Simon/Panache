import 'math_symbols.dart';

String convertLatex(String text) {
  var s = text.replaceAll(
    RegExp(r'\\(?:left|right|big|Big)g?[lmr]?(?![a-zA-Z])[ \t]*'),
    '',
  );
  s = s.replaceAllMapped(
    RegExp(r'\\begin\{([a-zA-Z*]+)\}(?:\[[tcb]\])?([\s\S]*?)\\end\{\1\}'),
    (m) {
      final rows = m[2]!.replaceAll(
        RegExp(r'[ \t]*\\\\\*?(?:\[[^\]]*\])?[ \t]*(?:\r?\n)?'),
        '\n',
      );
      if (m[1]!.contains('matrix')) {
        final brackets =
            {
              'pmatrix': ['(', ')'],
              'bmatrix': ['[', ']'],
              'Bmatrix': ['{', '}'],
              'vmatrix': ['|', '|'],
              'Vmatrix': ['|', '|'],
            }[m[1]] ??
            ['[', ']'];
        final content = rows
            .split('\n')
            .map(
              (r) => r
                  .split('&')
                  .map((c) => c.trim())
                  .where((c) => c.isNotEmpty)
                  .join('  '),
            )
            .where((r) => r.isNotEmpty)
            .join(' ; ');
        return '${brackets[0]} $content ${brackets[1]}';
      }
      return rows.replaceAll('&', '').trim();
    },
  );
  s = s.replaceAllMapped(
    RegExp(
      r'\\\[([\s\S]*?)\\\]|\\\(([\s\S]*?)\\\)|\$\$([\s\S]*?)\$\$|\$([^$\n]*?)\$',
    ),
    (m) => (m[1] ?? m[2] ?? m[3] ?? m[4]!).trim(),
  );
  s = s.replaceAll(
    RegExp(r'[ \t]*\\\\\*?(?:\[[^\]]*\])?[ \t]*(?:\r?\n|$)'),
    '\n',
  );
  return s
      .split('\n')
      .map((line) {
        final complex = RegExp(
          r'\\(?:frac|dfrac|tfrac|sqrt|sum|prod|int|cos|sin|tan|lim)\b',
        ).hasMatch(line);
        var result = _Parser(line).parse();
        if (complex) {
          // TeX ignores ordinary math whitespace; retain operator spacing used by the existing renderer.
          result = result
              .replaceAll(RegExp(r'[ \t]'), '')
              .replaceAll('⇒', line.contains(r'\implies') ? '  ⇒  ' : '⇒');
        }
        return result;
      })
      .join('\n');
}

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;
  String group() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    if (i == s.length) return '';
    if (s[i] == '{') {
      i++;
      return parse(closing: '}');
    }
    return s[i++];
  }

  String parse({String? closing}) {
    final out = StringBuffer();
    while (i < s.length) {
      final c = s[i++];
      if (c == closing) break;
      if (c == '{') {
        out.write(parse(closing: '}'));
        continue;
      }
      if (c == '^' || c == '_') {
        final value = group();
        final source = c == '^'
            ? '0123456789+-=()nixykm'
            : '0123456789+-=()aehijklmnoprstuvxy';
        final target = c == '^'
            ? '⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣʸᵏᵐ'
            : '₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵧ';
        out.write(
          value
              .split('')
              .map((x) => source.contains(x) ? target[source.indexOf(x)] : x)
              .join(),
        );
        continue;
      }
      if (c != r'\') {
        out.write(c);
        continue;
      }
      final start = i;
      while (i < s.length && RegExp('[a-zA-Z]').hasMatch(s[i])) {
        i++;
      }
      if (i == start && i < s.length) {
        final symbol = s[i++];
        out.write(mathSymbols[symbol] ?? symbol);
        continue;
      }
      final command = s.substring(start, i);
      if (['frac', 'dfrac', 'tfrac'].contains(command)) {
        final a = group(), b = group();
        out.write(
          {
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
                '4/3': '\uE001',
                '1/9': '\uE002',
                '1/10': '\uE003',
              }['$a/$b'] ??
              '($a)/($b)',
        );
      } else if (command == 'sqrt') {
        var root = '';
        if (i < s.length && s[i] == '[') {
          i++;
          root = parse(closing: ']');
        }
        out.write(
          '${root == '3'
              ? '∛'
              : root == '4'
              ? '∜'
              : '${root.isEmpty ? '' : root}√'}(${group()})',
        );
      } else if (command == 'boxed' && !s.substring(i).contains('}')) {
        out.write('boxed${s.substring(i)}');
        i = s.length;
      } else if ([
        'boxed',
        'text',
        'mathrm',
        'mathbf',
        'mathit',
        'operatorname',
        'textit',
        'textbf',
      ].contains(command)) {
        out.write(group());
      } else if (['bar', 'overline', 'hat', 'vec', 'dot'].contains(command)) {
        final accent = {
          'bar': '\u0304',
          'overline': '\u0305',
          'hat': '\u0302',
          'vec': '\u20d7',
          'dot': '\u0307',
        }[command]!;
        out.write(group().split('').map((c) => '$c$accent').join());
      } else {
        out.write(mathSymbols[command] ?? command);
      }
    }
    return out.toString();
  }
}
