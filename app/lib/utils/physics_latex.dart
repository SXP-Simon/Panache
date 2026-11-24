// Bounded physics-package aliases. Semantics follow physics.pdf §2.1 / §2.5:
// https://mirrors.ctan.org/macros/latex/contrib/physics/physics.pdf
// Starred, long-form and mixed partial derivatives stay intact.
const _maxSource = 32768;
const _maxGroup = 4096;
const _maxDepth = 16;
final _command = RegExp(r'\\([A-Za-z]+|[^A-Za-z])');
final _derivativeOrder = RegExp(r'\[([1-9]\d?|[A-Za-z])\]');
const _literalCommands = {
  'text',
  'textrm',
  'textbf',
  'textit',
  'texttt',
  'operatorname',
  'ce',
};
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

typedef _PhysicsArguments = ({
  String? operand,
  String? variable,
  String order,
  int end,
});

_PhysicsArguments? _readArguments(String source, int offset, String name) {
  final derivative = name == 'dv' || name == 'pdv';
  var order = '';
  offset = _skipSpace(source, offset);
  if (derivative && source.startsWith('[', offset)) {
    final option = _derivativeOrder.matchAsPrefix(source, offset);
    if (option == null) return null;
    order = option[1]!;
    offset = option.end;
  }

  final first = _groupAt(source, offset);
  if (first == null || first.body.trim().isEmpty) return null;
  if (!derivative) {
    return (operand: first.body, variable: null, order: '', end: first.end);
  }

  final second = _groupAt(source, first.end);
  final end = second?.end ?? first.end;
  final tailOffset = _skipSpace(source, end);
  final tail = tailOffset < source.length ? source[tailOffset] : '';
  if (tail == '{' || tail == '(' || tail == '[') return null;
  final variable = (second?.body ?? first.body).trim();
  if (!_variable.hasMatch(variable)) return null;
  return (
    operand: second == null ? null : first.body,
    variable: variable,
    order: order,
    end: end,
  );
}

String? _expandCommand(String name, _PhysicsArguments arguments, int depth) {
  final operand = arguments.operand;
  final body = operand == null ? '' : _normalizeFragment(operand, depth + 1);
  if (body == null) return null;

  final variable = arguments.variable;
  if (variable == null) {
    final delimiter = name == 'abs' ? '|' : r'\Vert';
    return '\\left$delimiter{$body}\\right$delimiter';
  }
  final differential = name == 'dv' ? r'\mathrm{d}' : r'\partial';
  final order = arguments.order;
  final power = order.isNotEmpty && order != '1' ? '^{$order}' : '';
  final numerator = body.isEmpty ? '' : '{$body}';
  return '\\frac{$differential$power$numerator}{$differential{$variable}$power}';
}

String? _normalizeFragment(String source, int depth) {
  if (depth > _maxDepth) return null;
  final result = StringBuffer();
  var cursor = 0, scan = 0;
  while (scan < source.length) {
    final matches = _command.allMatches(source, scan).iterator;
    if (!matches.moveNext()) break;
    final match = matches.current;
    scan = match.end;
    final name = match[1]!;
    if (_literalCommands.contains(name)) {
      scan = _groupAt(source, scan)?.end ?? scan;
      continue;
    }
    if (!const {'dv', 'pdv', 'abs', 'norm'}.contains(name)) continue;
    final arguments = _readArguments(source, scan, name);
    if (arguments == null) return null;
    final replacement = _expandCommand(name, arguments, depth);
    if (replacement == null) return null;
    result.write(source.substring(cursor, match.start));
    result.write(replacement);
    cursor = arguments.end;
    scan = arguments.end;
  }
  result.write(source.substring(cursor));
  return result.toString();
}

String normalizePhysicsLatex(String source) {
  if (source.length > _maxSource) return source;
  return _normalizeFragment(source, 0) ?? source;
}
