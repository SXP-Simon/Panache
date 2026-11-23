// Quote a literal occurrence at the document boundary before inserting tokens.
const markdownTokenStart = '\uFDD0';

/// Only exact tokens issued by this cleanup stage can restore a saved value.
class MarkdownPlaceholders {
  MarkdownPlaceholders(this.prefix, this.suffix);

  final String prefix;
  final String suffix;
  final _values = <String, String>{};
  late final _pattern = RegExp('${RegExp.escape(prefix)}[0-9]+$suffix');

  String save(String value) {
    final token = '$prefix${_values.length}$suffix';
    _values[token] = value;
    return token;
  }

  String restore(String text) => _values.isEmpty
      ? text
      : text.replaceAllMapped(_pattern, (match) {
          final token = match[0]!;
          return _values[token] ?? token;
        });
}

({String text, String Function(String) restore}) protectMarkdownCode(
  String source, {
  bool inline = true,
}) {
  var prefix = '${markdownTokenStart}CODE';
  while (source.contains(prefix)) {
    prefix += markdownTokenStart;
  }
  // A fenced block can be temporarily hidden from the inline pass.
  final values = MarkdownPlaceholders(prefix, inline ? '\uE111' : '\uE113');

  final lines = source.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');
  final output = <String>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final opening = RegExp(r'^( {0,3})(`{3,}|~{3,})(.*)$').firstMatch(line);
    final fence = opening?[2];
    if (fence == null || (fence[0] == '`' && opening![3]!.contains('`'))) {
      output.add(line);
      continue;
    }
    final indent = opening![1]!.length;
    final body = <String>[];
    for (index++; index < lines.length; index++) {
      final current = lines[index];
      final closing = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$')
          .firstMatch(current)?[1];
      if (closing != null &&
          closing[0] == fence[0] &&
          closing.length >= fence.length) {
        break;
      }
      final leading = RegExp(r'^ *').firstMatch(current)![0]!.length;
      body.add(current.substring(indent < leading ? indent : leading));
    }
    output.add(
      values.save(body.where((line) => line.trim().isNotEmpty).join('\n')),
    );
  }
  final joined = output.join('\n');
  final result = StringBuffer();
  final runs = inline
      ? RegExp(r'`+').allMatches(joined).toList()
      : <RegExpMatch>[];
  final nextByLength = <int, int>{};
  final nextRun = List<int?>.filled(runs.length, null);
  for (var i = runs.length - 1; i >= 0; i--) {
    final length = runs[i].end - runs[i].start;
    nextRun[i] = nextByLength[length];
    nextByLength[length] = i;
  }
  var cursor = 0;
  for (var index = 0; index < runs.length; index++) {
    final opening = runs[index];
    final closing = nextRun[index];
    if (closing == null) continue;
    var value = joined
        .substring(opening.end, runs[closing].start)
        .replaceAll('\n', ' ');
    if (value.startsWith(' ') &&
        value.endsWith(' ') &&
        value.trim().isNotEmpty) {
      value = value.substring(1, value.length - 1);
    }
    result.write(joined.substring(cursor, opening.start));
    result.write(values.save(value));
    cursor = runs[closing].end;
    index = closing;
  }
  result.write(joined.substring(cursor));
  return (text: result.toString(), restore: values.restore);
}

String stripMarkdownLinks(String source) {
  final output = StringBuffer();
  final closes = <int, int>{};
  final stack = <int>[];
  for (var i = 0; i < source.length; i++) {
    if (source[i] == r'\') {
      i++;
      continue;
    }
    if (source[i] == '\n') {
      stack.clear();
    } else if (source[i] == '(') {
      stack.add(i);
    } else if (source[i] == ')' && stack.isNotEmpty) {
      closes[stack.removeLast()] = i + 1;
    }
  }
  var cursor = 0;
  for (final match in RegExp(r'!?\[([^\]\n]*)\]\(').allMatches(source)) {
    if (match.start < cursor) continue;
    final end = closes[match.end - 1];
    if (end == null) continue;
    output.write(source.substring(cursor, match.start));
    output.write(match[1]);
    cursor = end;
  }
  output.write(source.substring(cursor));
  return output.toString();
}
