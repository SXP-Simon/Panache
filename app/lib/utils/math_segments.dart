class MathSegment {
  const MathSegment(
    this.start,
    this.end,
    this.body, {
    this.math = false,
    this.display = false,
    this.safeMathLiteral = false,
  });
  final int start, end;
  final String body;
  final bool math, display, safeMathLiteral;
}

bool _escaped(String s, int i) {
  var count = 0;
  while (i > 0 && s[--i] == r'\') {
    count++;
  }
  return count.isOdd;
}

bool withinMathBudget(String s) {
  if (s.length > 16000) return false;
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == r'\') {
      i++;
      continue;
    }
    if (s[i] == '{' && ++depth > 64) return false;
    if (s[i] == '}') depth--;
  }
  return true;
}

// Bare paired delimiters are one formula region, not paths or Markdown links.
int bareDelimiterEnd(String text, int start) {
  var depth = 0;
  for (final token in RegExp(r'\\(left|right)\b').allMatches(text, start)) {
    depth += token[1] == 'left' ? 1 : -1;
    if (depth != 0) continue;
    final delimiter = RegExp(r'^[ \t]*(?:\\[a-zA-Z]+|\\.|[^\s])')
        .firstMatch(text.substring(token.end));
    return delimiter == null ? start : token.end + delimiter[0]!.length;
  }
  return start;
}

final _env = RegExp(r'^\\(begin|end)\{([a-zA-Z][a-zA-Z0-9*]*)\}');

// Explicit math and literal ranges share one scanner so conversion and Markdown
// cleanup agree about where source must be preserved.
List<MathSegment> scanMathSegments(String text) {
  final result = <MathSegment>[];
  final links = _LinkDelimiters(text);
  for (var cursor = 0; cursor < text.length;) {
    if (text.startsWith(r'\left', cursor)) {
      final end = bareDelimiterEnd(text, cursor);
      if (end > cursor) {
        cursor = end;
        continue;
      }
    }
    final segment = _segmentAt(text, cursor, links);
    if (segment == null) {
      cursor += text.startsWith(r'\\', cursor) ? 2 : 1;
    } else {
      result.add(segment);
      cursor = segment.end;
    }
  }
  return result;
}

MathSegment? _segmentAt(String text, int start, _LinkDelimiters links) {
  final c = text[start];
  if (c == '`' || (c == '~' && text.startsWith('~~~', start))) {
    final end = _codeEnd(text, start, c);
    return MathSegment(start, end, text.substring(start, end));
  }
  if (c == '⟦') {
    final end = _matrixEnd(text, start);
    return MathSegment(
      start,
      end,
      text.substring(start, end),
      safeMathLiteral: true,
    );
  }
  final boundary =
      start == 0 || RegExp(r'''[\s"'([{:：，；]''').hasMatch(text[start - 1]);
  if (!boundary && !{'h', 'f', r'\', r'$', '!', '['}.contains(c)) return null;
  final tail = text.substring(start, (start + 512).clamp(0, text.length));
  final literal = _pathEnd(text, start, tail, boundary) ?? links.endAt(start);
  if (literal != null) {
    return MathSegment(start, literal, text.substring(start, literal));
  }
  if ((c != r'\' && c != r'$') ||
      text.startsWith(r'\\', start) ||
      _escaped(text, start)) {
    return null;
  }
  final enclosure = RegExp(r'^\\(?:boxed|fbox)\s*\{').firstMatch(tail);
  if (enclosure != null) return _enclosure(text, start, start + enclosure.end);
  final env = _env.firstMatch(tail);
  if (env != null && env[1] == 'begin') return _environment(text, start, env);
  final delimiter = _Delimiter.at(text, start);
  return delimiter == null
      ? null
      : _delimitedMath(text, start, tail, delimiter);
}

class _LinkDelimiters {
  // Index link delimiters once: incomplete pasted links must not scan the rest
  // of a long document again at every opening bracket.
  _LinkDelimiters(this.text);
  final String text;
  late final _index = _buildIndex();

  ({Map<int, int> ends, List<int> brackets}) _buildIndex() {
    final linkEnds = <int, int>{}, brackets = <int>[];
    final parentheses = <int>[];
    for (var i = 0; i < text.length; i++) {
      if (text[i] == r'\') {
        i++;
        continue;
      }
      if (text[i] == ']') brackets.add(i);
      if (text[i] == '(') parentheses.add(i);
      if (text[i] == ')' && parentheses.isNotEmpty) {
        linkEnds[parentheses.removeLast()] = i + 1;
      }
    }
    return (ends: linkEnds, brackets: brackets);
  }

  int? nextBracket(int start) {
    final brackets = _index.brackets;
    var low = 0, high = brackets.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (brackets[middle] < start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == brackets.length ? null : brackets[low];
  }

  int? endAt(int start) {
    final image = text.startsWith('![', start);
    if (!image && text[start] != '[') return null;
    final bracket = nextBracket(start + (image ? 2 : 1));
    if (bracket == null) return null;
    var end = bracket + 1;
    if (end < text.length && text[end] == '(') {
      end = _index.ends[end] ?? text.length;
    }
    return image || text[end - 1] == ')' ? end : null;
  }
}

int _codeEnd(String text, int start, String c) {
  var count = 1;
  while (start + count < text.length && text[start + count] == c) {
    count++;
  }
  final fence = c * count;
  var end = text.indexOf(fence, start + count);
  while (end >= 0 &&
      ((end > 0 && text[end - 1] == c) ||
          (end + count < text.length && text[end + count] == c))) {
    end = text.indexOf(fence, end + count);
  }
  final newline = text.indexOf('\n', start);
  if (end >= 0) return end + count;
  return count >= 3 || newline < 0 ? text.length : newline;
}

int _matrixEnd(String text, int start) {
  var end = start + 1, depth = 1;
  var quoted = false, escaped = false;
  while (end < text.length && depth > 0) {
    final value = text[end++];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (value == r'\') {
        escaped = true;
      } else if (value == '"') {
        quoted = false;
      }
      continue;
    }
    if (value == '"') {
      quoted = true;
    } else if (value == '⟦') {
      depth++;
    } else if (value == '⟧') {
      depth--;
    }
  }
  return end;
}

int? _pathEnd(String text, int start, String tail, bool boundary) {
  final url = RegExp(r'^(?:(?:https?|ftp)://|www\.)').hasMatch(tail);
  final path =
      RegExp(r'^[a-zA-Z]:[\\/]|^\\\\[^\s\\/]+[\\/][^\s]').hasMatch(tail) ||
      (boundary &&
          RegExp(
            r'''^(?:/[^\s/]+/|\.{1,2}/)[^\s]|^(?:[\p{L}\p{N}_.-]{2,}[\\/]|[\p{L}\p{N}_.-]+[\\/][^\s<>"']*\.[a-zA-Z0-9]{1,10}(?=$|[\s.,;:)]))''',
            unicode: true,
          ).hasMatch(tail));
  if (url || path) {
    var end = start;
    final stop = url ? RegExp(r'[\s<>，。；：！？]') : RegExp(r'''[\s<>"'，。；：！？]''');
    while (end < text.length && !stop.hasMatch(text[end])) {
      end++;
    }
    return end;
  }
  return null;
}

MathSegment _enclosure(String text, int start, int contentStart) {
  var end = contentStart, depth = 1;
  while (end < text.length && depth > 0) {
    if (text[end] == r'\') {
      end += 2;
      continue;
    }
    if (text[end] == '{') depth++;
    if (text[end] == '}') depth--;
    end++;
  }
  final closed = depth == 0;
  if (!closed) end = text.length;
  final body = text.substring(start, end);
  final valid = closed && withinMathBudget(body);
  return MathSegment(start, end, body, math: valid, safeMathLiteral: !valid);
}

int? _environmentEnd(String text, int contentStart, String name) {
  final stack = <String>[name];
  var end = contentStart;
  while (end < text.length) {
    if (text[end] == '%' && !_escaped(text, end)) {
      final newline = text.indexOf('\n', end);
      end = newline < 0 ? text.length : newline + 1;
      continue;
    }
    if (text.startsWith(r'\\', end)) {
      end += 2;
      continue;
    }
    final tag = text[end] == r'\'
        ? _env.firstMatch(
            text.substring(end, (end + 100).clamp(0, text.length)),
          )
        : null;
    if (tag == null) {
      end++;
      continue;
    }
    end += tag[0]!.length;
    if (tag[1] == 'begin') {
      stack.add(tag[2]!);
      if (stack.length > 64) {
        return null;
      }
    } else {
      if (stack.removeLast() != tag[2]) {
        return null;
      }
      if (stack.isEmpty) {
        return end;
      }
    }
  }
  return null;
}

MathSegment _environment(String text, int start, RegExpMatch opening) {
  final name = opening[2]!;
  final close = _environmentEnd(text, start + opening.end, name);
  final end = close ?? text.length;
  final body = text.substring(start, end);
  // Circuit topology and labels belong to the engine and must stay editable.
  final math = close != null && withinMathBudget(body) && name != 'circuitikz';
  return MathSegment(
    start,
    end,
    body,
    math: math,
    display: true,
    safeMathLiteral: !math,
  );
}

enum _Delimiter {
  displayDollar(r'$$', r'$$', display: true),
  inlineDollar(r'$', r'$'),
  bracket(r'\[', r'\]', display: true),
  paren(r'\(', r'\)');

  const _Delimiter(this.open, this.close, {this.display = false});
  final String open, close;
  final bool display;

  static _Delimiter? at(String text, int start) {
    for (final delimiter in values) {
      if (text.startsWith(delimiter.open, start)) return delimiter;
    }
    return null;
  }
}

({int end, bool closed}) _closingDelimiter(
  String text,
  int content,
  _Delimiter delimiter,
) {
  final single = delimiter == _Delimiter.inlineDollar;
  for (var end = content; end < text.length; end++) {
    if (single && (text[end] == '\n' || text[end] == '\r')) {
      return (end: end, closed: false);
    }
    if (!text.startsWith(delimiter.close, end) || _escaped(text, end)) continue;
    if (single &&
        ((end > 0 && text[end - 1] == r'$') ||
            (end + 1 < text.length && text[end + 1] == r'$'))) {
      continue;
    }
    return (end: end, closed: true);
  }
  return (end: text.length, closed: false);
}

int? _currencyEnd(
  String text,
  String tail,
  int start,
  int end,
  String body,
  bool closed,
) {
  final amount = RegExp(r'^\$\d[\d,.]*').firstMatch(tail);
  final amountEnd = start + (amount?.end ?? 0);
  final boundary =
      amount != null &&
      (amountEnd >= text.length ||
          !RegExp(r'[a-zA-Z+\-*/^_={\\<>]').hasMatch(text[amountEnd]));
  final currency =
      closed &&
      RegExp(r'^\d[\d,.]*(?:[ \t]+[a-zA-Z]+)*[ \t]*$').hasMatch(body) &&
      ((end + 1 < text.length && RegExp(r'\d').hasMatch(text[end + 1])) ||
          RegExp(r'\s$').hasMatch(body));
  if (currency) return amount == null ? start + 1 : amountEnd;
  if (boundary &&
      (!closed ||
          (end > amountEnd &&
              RegExp(r'^[\s;:!?，。；：！？]+$')
                  .hasMatch(text.substring(amountEnd, end))))) {
    return amountEnd;
  }
  return null;
}

MathSegment _delimitedMath(
  String text,
  int start,
  String tail,
  _Delimiter delimiter,
) {
  final content = start + delimiter.open.length;
  final (:end, :closed) = _closingDelimiter(text, content, delimiter);
  final body = text.substring(content, end);
  if (delimiter == _Delimiter.inlineDollar) {
    final amount = _currencyEnd(text, tail, start, end, body, closed);
    if (amount != null) {
      return MathSegment(start, amount, text.substring(start, amount));
    }
  }
  final valid = closed && withinMathBudget(body);
  return MathSegment(
    start,
    closed ? end + delimiter.close.length : end,
    body,
    math: valid,
    display: delimiter.display,
    safeMathLiteral: !valid,
  );
}
