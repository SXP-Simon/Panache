({String text, String Function(String) restore}) protectMarkdownCode(
  String source, {
  bool inline = true,
}) {
  var prefix = '\uE110CODE';
  while (source.contains(prefix)) {
    prefix += '\uE110';
  }
  final values = <String>[];
  String save(String value) {
    values.add(value);
    return '$prefix${values.length - 1}\uE111';
  }

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
    output.add(save(body.join('\n')));
  }
  final joined = output.join('\n');
  final result = StringBuffer();
  final runs = inline
      ? RegExp(r'`+').allMatches(joined).toList()
      : <RegExpMatch>[];
  var cursor = 0;
  for (var index = 0; index < runs.length; index++) {
    final opening = runs[index];
    var closing = index + 1;
    while (closing < runs.length &&
        runs[closing][0]!.length != opening[0]!.length) {
      closing++;
    }
    if (closing == runs.length) break;
    var value = joined
        .substring(opening.end, runs[closing].start)
        .replaceAll('\n', ' ');
    if (value.startsWith(' ') &&
        value.endsWith(' ') &&
        value.trim().isNotEmpty) {
      value = value.substring(1, value.length - 1);
    }
    result.write(joined.substring(cursor, opening.start));
    result.write(save(value));
    cursor = runs[closing].end;
    index = closing;
  }
  result.write(joined.substring(cursor));
  return (
    text: result.toString(),
    restore: (value) => value.replaceAllMapped(
      RegExp('${RegExp.escape(prefix)}(\\d+)\uE111'),
      (match) => values[int.parse(match[1]!)],
    ),
  );
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
