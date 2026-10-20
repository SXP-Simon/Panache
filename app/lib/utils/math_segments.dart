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
  var cursor = 0;
  void add(
    int start,
    int end, {
    String? body,
    bool math = false,
    bool display = false,
    bool safe = false,
  }) {
    result.add(
      MathSegment(
        start,
        end,
        body ?? text.substring(start, end),
        math: math,
        display: display,
        safeMathLiteral: safe,
      ),
    );
    cursor = end;
  }

  while (cursor < text.length) {
    final start = cursor, c = text[cursor];
    if (c == '`' || (c == '~' && text.startsWith('~~~', cursor))) {
      var count = 1;
      while (cursor + count < text.length && text[cursor + count] == c) {
        count++;
      }
      final fence = c * count;
      var end = text.indexOf(fence, cursor + count);
      while (end >= 0 &&
          ((end > 0 && text[end - 1] == c) ||
              (end + count < text.length && text[end + count] == c))) {
        end = text.indexOf(fence, end + count);
      }
      final newline = text.indexOf('\n', cursor);
      add(
        start,
        end < 0
            ? (count >= 3 || newline < 0 ? text.length : newline)
            : end + count,
      );
      continue;
    }
    if (text.startsWith(r'\left', cursor)) {
      final end = bareDelimiterEnd(text, cursor);
      if (end > cursor) {
        cursor = end;
        continue;
      }
    }
    final boundary =
        cursor == 0 || RegExp(r'''[\s"'([{:：，；]''').hasMatch(text[cursor - 1]);
    if (!boundary && !{'h', 'f', r'\', r'$', '!', '['}.contains(c)) {
      cursor++;
      continue;
    }
    // Prefix matching never copies the remaining document.
    final tail = text.substring(cursor, (cursor + 512).clamp(0, text.length));
    final url = RegExp(r'^(?:(?:https?|ftp)://|www\.)').hasMatch(tail);
    final path =
        RegExp(r'^[a-zA-Z]:[\\/]|^\\\\[^\s\\/]+[\\/][^\s]').hasMatch(tail) ||
        (boundary &&
            RegExp(
              r'''^(?:/[^\s/]+/|\.{1,2}/)[^\s]|^(?:[\p{L}\p{N}_.-]{2,}[\\/]|[\p{L}\p{N}_.-]+[\\/][^\s<>"']*\.[a-zA-Z0-9]{1,10}(?=$|[\s.,;:)]))''',
              unicode: true,
            ).hasMatch(tail));
    if (url || path) {
      var end = cursor;
      final stop = url
          ? RegExp(r'[\s<>，。；：！？]')
          : RegExp(r'''[\s<>"'，。；：！？]''');
      while (end < text.length && !stop.hasMatch(text[end])) {
        end++;
      }
      add(start, end);
      continue;
    }
    if (text.startsWith('![', cursor) || c == '[') {
      var end = cursor + (c == '!' ? 2 : 1);
      while (end < text.length && (text[end] != ']' || _escaped(text, end))) {
        end++;
      }
      if (end < text.length) {
        end++;
        if (end < text.length && text[end] == '(') {
          var depth = 1;
          for (end++; end < text.length && depth > 0; end++) {
            if (_escaped(text, end)) continue;
            if (text[end] == '(') depth++;
            if (text[end] == ')') depth--;
          }
        }
        if (c == '!' || text[end - 1] == ')') {
          add(start, end);
          continue;
        }
      }
    }
    if (text.startsWith(r'\\', cursor)) {
      cursor += 2;
      continue;
    }
    if ((c == r'\' || c == r'$') && !_escaped(text, cursor)) {
      // Keep a bare enclosure together: an environment inside it must not be
      // split from its enclosing command before the formula parser sees it.
      final enclosure = RegExp(r'^\\(?:boxed|fbox)\s*\{').firstMatch(tail);
      if (enclosure != null) {
        var end = cursor + enclosure[0]!.length, depth = 1;
        while (end < text.length && depth > 0) {
          if (text[end] == r'\') {
            end += 2;
            continue;
          }
          if (text[end] == '{') depth++;
          if (text[end] == '}') depth--;
          end++;
        }
        if (depth == 0) {
          final body = text.substring(start, end);
          final valid = withinMathBudget(body);
          add(start, end, math: valid, safe: !valid);
          continue;
        }
        add(start, text.length, safe: true);
        continue;
      }
      final env = _env.firstMatch(tail);
      if (env != null && env[1] == 'begin') {
        final stack = <String>[env[2]!];
        var end = cursor + env[0]!.length, valid = false;
        while (end < text.length) {
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
              end = text.length;
              break;
            }
          } else {
            if (stack.removeLast() != tag[2]) {
              end = text.length;
              break;
            }
            if (stack.isEmpty) {
              valid = true;
              break;
            }
          }
        }
        final body = text.substring(start, end);
        valid = valid && withinMathBudget(body);
        add(start, end, math: valid, display: true, safe: !valid);
        continue;
      }
      String? open, close;
      var display = false;
      if (text.startsWith(r'$$', cursor)) {
        open = close = r'$$';
        display = true;
      } else if (c == r'$') {
        open = close = r'$';
      } else if (text.startsWith(r'\[', cursor)) {
        open = r'\[';
        close = r'\]';
        display = true;
      } else if (text.startsWith(r'\(', cursor)) {
        open = r'\(';
        close = r'\)';
      }
      if (open != null) {
        var end = cursor + open.length;
        var closed = false, currency = false;
        while (end < text.length) {
          if (open == r'$' && (text[end] == '\n' || text[end] == '\r')) break;
          if (text.startsWith(close!, end) && !_escaped(text, end)) {
            if (close == r'$' &&
                ((end > 0 && text[end - 1] == r'$') ||
                    (end + 1 < text.length && text[end + 1] == r'$'))) {
              end++;
              continue;
            }
            final body = text.substring(cursor + open.length, end);
            currency =
                open == r'$' &&
                RegExp(r'^\d[\d,.]*(?:[ \t]+[a-zA-Z]+)*[ \t]*$')
                    .hasMatch(body) &&
                ((end + 1 < text.length &&
                        RegExp(r'\d').hasMatch(text[end + 1])) ||
                    RegExp(r'\s$').hasMatch(body));
            closed = true;
            break;
          }
          end++;
        }
        final amount = open == r'$'
            ? RegExp(r'^\$\d[\d,.]*').firstMatch(tail)
            : null;
        final amountEnd = cursor + (amount?[0]?.length ?? 0);
        final amountBoundary =
            amount != null &&
            (amountEnd >= text.length ||
                !RegExp(r'[a-zA-Z+\-*/^_={\\<>]').hasMatch(text[amountEnd]));
        currency =
            currency ||
            (amountBoundary &&
                closed &&
                end > amountEnd &&
                RegExp(r'^[\s;:!?，。；：！？]+$')
                    .hasMatch(text.substring(amountEnd, end)));
        if (currency || (amountBoundary && !closed)) {
          add(start, amount == null ? cursor + 1 : amountEnd);
          continue;
        }
        final body = text.substring(start + open.length, end);
        final valid = closed && withinMathBudget(body);
        add(
          start,
          closed ? end + close!.length : end,
          body: body,
          math: valid,
          display: display,
          safe: !valid,
        );
        continue;
      }
    }
    cursor++;
  }
  return result;
}
