// Bounded physics-package aliases. Semantics follow physics.pdf §2.1 / §2.5:
// https://mirrors.ctan.org/macros/latex/contrib/physics/physics.pdf
// Starred, long-form and mixed partial derivatives stay intact.
const _maxSource = 32768;
const _maxGroup = 4096;
const _maxDepth = 16;
final _variable = RegExp(
  r'^(?:[A-Za-zΑ-Ωα-ωϑϕϖϱϵϰ]|\\[A-Za-z]+)(?:_(?:[A-Za-z0-9]|\{(?:[A-Za-z0-9]{1,16}|\\[A-Za-z]+)\}))?$',
);

int _skipSpace(String source, int offset) {
  while (offset < source.length && source[offset].trim().isEmpty) {
    offset++;
  }
  return offset;
}

({String body, int end})? _groupAt(String source, int offset) {
  final start = _skipSpace(source, offset);
  if (start >= source.length || source[start] != '{') return null;
  var depth = 1;
  for (var cursor = start + 1; cursor < source.length; cursor++) {
    if (cursor - start > _maxGroup) return null;
    if (source[cursor] == r'\') {
      cursor++;
    } else if (source[cursor] == '{') {
      if (++depth > _maxDepth) return null;
    } else if (source[cursor] == '}' && --depth == 0) {
      return (body: source.substring(start + 1, cursor), end: cursor + 1);
    }
  }
  return null;
}

String? _normalizeFragment(String source, int depth) {
  if (depth > _maxDepth) return null;
  final commands = RegExp(r'\\([A-Za-z]+|[^A-Za-z])');
  final result = StringBuffer();
  var cursor = 0, scan = 0;
  while (scan < source.length) {
    final matches = commands.allMatches(source, scan).iterator;
    if (!matches.moveNext()) break;
    final match = matches.current;
    final start = match.start;
    scan = match.end;
    final name = match.group(1)!;
    if (const [
      'text',
      'textrm',
      'textbf',
      'textit',
      'texttt',
      'operatorname',
      'ce',
    ].contains(name)) {
      final text = _groupAt(source, scan);
      if (text != null) scan = text.end;
      continue;
    }
    if (!const ['dv', 'pdv', 'abs', 'norm'].contains(name)) continue;
    var offset = _skipSpace(source, scan);
    var order = '';
    if ((name == 'dv' || name == 'pdv') &&
        offset < source.length &&
        source[offset] == '[') {
      final option = RegExp(r'^\[([1-9]\d?|[A-Za-z])\]')
          .firstMatch(source.substring(offset));
      if (option == null) return null;
      order = option.group(1)!;
      offset += option.end;
    }
    final first = _groupAt(source, offset);
    if (first == null || first.body.trim().isEmpty) return null;
    var end = first.end;
    final String replacement;
    if (name == 'abs' || name == 'norm') {
      final body = _normalizeFragment(first.body, depth + 1);
      if (body == null) return null;
      final delimiter = name == 'abs' ? '|' : r'\Vert';
      replacement = '\\left$delimiter{$body}\\right$delimiter';
    } else {
      final second = _groupAt(source, first.end);
      end = second?.end ?? first.end;
      final tailOffset = _skipSpace(source, end);
      final tail = tailOffset < source.length ? source[tailOffset] : '';
      if (tail == '{' || tail == '(' || tail == '[') return null;
      final variable = (second?.body ?? first.body).trim();
      if (!_variable.hasMatch(variable)) return null;
      final body = second != null
          ? _normalizeFragment(first.body, depth + 1)
          : '';
      if (body == null) return null;
      final differential = name == 'dv' ? r'\mathrm{d}' : r'\partial';
      final power = order.isNotEmpty && order != '1' ? '^{$order}' : '';
      final numerator = body.isEmpty ? '' : '{$body}';
      replacement =
          '\\frac{$differential$power$numerator}'
          '{$differential{$variable}$power}';
    }
    result.write(source.substring(cursor, start));
    result.write(replacement);
    cursor = end;
    scan = end;
  }
  result.write(source.substring(cursor));
  return result.toString();
}

String normalizePhysicsLatex(String source) {
  if (source.length > _maxSource) return source;
  return _normalizeFragment(source, 0) ?? source;
}
