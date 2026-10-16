import 'math_segments.dart';
import 'image_markers.dart';

String expandImages(String text, Map<String, String> images) {
  var result = text.replaceAllMapped(
    RegExp(r'!\[(插图[ \t]*[#:_-]?[ \t]*(\d+)(?:\|[^\]]+)?)\](?!\()'),
    (m) => images[m[2]] == null ? m[0]! : '\n![${m[1]}](${images[m[2]]})\n',
  );
  result = result.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\(img:?_?(\d+)\)'),
    (m) => images[m[2]] == null ? m[0]! : '\n![${m[1]}](${images[m[2]]})\n',
  );
  return result;
}

String collapseImages(String text, Map<String, String> images) =>
    text.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\((data:image/[^;]+;base64,[A-Za-z0-9+/=\s]+)\)'),
      (m) {
        final data = m[2]!.replaceAll(RegExp(r'\s'), '');
        final existing = images.entries
            .where((e) => e.value == data)
            .firstOrNull;
        final id = existing?.key ?? nextIllustrationId(images, text);
        images[id] = data;
        final scale = m[1]!.contains('|') ? '|${m[1]!.split('|').last}' : '';
        return '![插图 $id$scale]';
      },
    );

String cleanMarkdown(
  String text, {
  String tableMode = 'list',
  bool english = false,
}) {
  var s = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final protected = <String>[];
  var tokenPrefix = '\uE100HW';
  while (s.contains(tokenPrefix)) {
    tokenPrefix += '\uE100';
  }
  String protect(String source) {
    protected.add(source);
    return '$tokenPrefix${protected.length - 1}\uE101';
  }

  final math = StringBuffer();
  var cursor = 0;
  for (final segment in scanMathSegments(s)) {
    math.write(s.substring(cursor, segment.start));
    final source = s.substring(segment.start, segment.end);
    // Links and images retain the existing Markdown extraction rules.
    math.write(
      source.startsWith('![') || source.startsWith('[')
          ? source
          : protect(source),
    );
    cursor = segment.end;
  }
  math.write(s.substring(cursor));
  s = math.toString();
  final bareMath = StringBuffer();
  cursor = 0;
  for (final match in RegExp(r'\\left\b').allMatches(s)) {
    if (match.start < cursor) continue;
    final end = bareDelimiterEnd(s, match.start);
    if (end <= match.start) continue;
    bareMath.write(s.substring(cursor, match.start));
    bareMath.write(protect(s.substring(match.start, end)));
    cursor = end;
  }
  bareMath.write(s.substring(cursor));
  s = bareMath.toString();
  s = s.replaceAllMapped(
    RegExp(
      r'!\[[^\]]*\]\((?:data:image/[^)]+|img:?_?\d+)\)|!\[插图(?:[ \t]*[#:_-]?[ \t]*\d+)?(?:\|[^\]]+)?\](?!\()',
    ),
    (m) {
      return protect(m[0]!);
    },
  );
  s = s.replaceFirst(
    RegExp(r'^---[ \t]*\n(?=[ \t]*[\w-]+[ \t]*:)[\s\S]*?\n---[ \t]*(?:\n|$)'),
    '',
  );
  s = s
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s
      .replaceAll(RegExp(r'<hr\s*/?>', caseSensitive: false), '\n---\n')
      .replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');
  s = s.replaceAllMapped(
    RegExp(r'```[^\n]*\n([\s\S]*?)```|~~~[^\n]*\n([\s\S]*?)~~~'),
    (m) => m[1] ?? m[2]!,
  );
  s = s.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1]!);
  s = s.replaceAllMapped(RegExp(r'!?\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  final output = <String>[], table = <String>[];
  void flush() {
    if (table.isEmpty) return;
    final rows = table
        .where((line) => !RegExp(r'^[\s|:\-]+$').hasMatch(line))
        .map(
          (line) => line
              .trim()
              .replaceAll(RegExp(r'^\||\|$'), '')
              .split('|')
              .map((c) => c.trim())
              .toList(),
        )
        .toList();
    if (rows.isNotEmpty) {
      if (tableMode == 'list' && rows.length > 1) {
        final headers = rows.first;
        for (var i = 1; i < rows.length; i++) {
          final row = rows[i];
          final fields = [
            for (var j = 1; j < row.length; j++)
              '${j < headers.length ? headers[j] : '${english ? 'Column' : '列'}${j + 1}'}: ${row[j].isEmpty ? '-' : row[j]}',
          ];
          output.add(
            '$i. ${headers.first}: ${row.first}${fields.isEmpty ? '' : ' (${fields.join('; ')})'}',
          );
        }
      } else if (tableMode == 'aligned') {
        int width(String value) =>
            value.runes.fold(0, (a, b) => a + (b > 255 ? 2 : 1));
        final columns = rows
            .map((r) => r.length)
            .reduce((a, b) => a > b ? a : b);
        final widths = List.generate(
          columns,
          (i) => rows
              .map((r) => i < r.length ? width(r[i]) : 0)
              .reduce((a, b) => a > b ? a : b),
        );
        output.addAll(
          rows.map(
            (r) => [
              for (var i = 0; i < r.length; i++)
                r[i] + ' ' * (widths[i] - width(r[i]) + 2),
            ].join().trimRight(),
          ),
        );
      } else {
        output.addAll(
          rows.map((r) => r.join(tableMode == 'raw_pipe' ? ' | ' : '  ')),
        );
      }
    }
    table.clear();
  }

  var listContinuation = false;
  for (var line in s.split('\n')) {
    if (RegExp(r'^\s*\|.*\|\s*$').hasMatch(line)) {
      table.add(line);
      continue;
    }
    flush();
    if (line.trim().isEmpty) listContinuation = false;
    final listItem = RegExp(r'^[ \t]*(?:>[ \t]*)*[-*+][ \t]+').hasMatch(line);
    if (listItem) listContinuation = true;
    if (listContinuation && RegExp(r'^[ \t]+').hasMatch(line)) {
      line = line.trimLeft();
    } else if (!listItem && !RegExp(r'^[ \t]*>').hasMatch(line)) {
      listContinuation = false;
    }
    if (!line.trimLeft().startsWith('>>>')) {
      line = line.replaceFirst(RegExp(r'^[ \t]*(?:>[ \t]*)+'), '');
    }
    line = line
        .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
        .replaceFirst(RegExp(r'^\s*[-*+]\s+\[[ xX]\]\s+'), '')
        .replaceFirst(RegExp(r'^\s*[-*+]\s+'), '');
    if (RegExp(r'^\s*([*_\-]\s*){3,}\s*$').hasMatch(line)) line = '---';
    output.add(line.trimRight());
  }
  flush();
  s = output.join('\n');
  for (final marker in ['***', '___', '**', '__', '~~', '==']) {
    s = s.replaceAllMapped(
      RegExp('${RegExp.escape(marker)}(.+?)${RegExp.escape(marker)}'),
      (m) => m[1]!,
    );
  }
  s = s.replaceAllMapped(
    RegExp(r'(^|[^\w*])\*([^\s*][^*\n]*?)\*(?=[^\w*]|$)'),
    (m) => '${m[1]}${m[2]}',
  );
  s = s.replaceAllMapped(
    RegExp(r'(^|[^\w_])_([^\s_][^_\n]*?)_(?=[^\w_]|$)'),
    (m) => '${m[1]}${m[2]}',
  );
  s = s.replaceAllMapped(
    RegExp('${RegExp.escape(tokenPrefix)}(\\d+)\uE101'),
    (m) => protected[int.parse(m[1]!)],
  );
  return s
      .split('\n')
      .where((line) => line.trim().isNotEmpty && line.trim() != '---')
      .join('\n')
      .trim();
}

String formatLetter(String body, String signature, String date) {
  final lines = body
      .replaceAll('\r', '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  return [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startsWith('>>>') ||
          RegExp(r'^-{3,}$').hasMatch(lines[i]) ||
          (i == 0 && RegExp(r'[：:]$').hasMatch(lines[i])))
        lines[i]
      else
        '　　${lines[i]}',
    ...[signature, date]
        .expand((s) => s.split('\n'))
        .map((s) => s.replaceFirst(RegExp(r'^\s*>>>\s*'), '').trim())
        .where((s) => s.isNotEmpty)
        .map((s) => '>>>$s'),
  ].join('\n');
}

({String body, String signature, String date}) extractLetterEnding(
  String text,
) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final indexes = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].trim().isNotEmpty) i,
  ];
  final removed = <int>{};
  String strip(String s) => s.replaceFirst(RegExp(r'^\s*>>>\s*'), '').trim();
  bool dateLine(String s) =>
      RegExp(
        r'^(?:\d{4}\s*(?:年|[./-])\s*)?\d{1,2}\s*(?:月|[./-])\s*\d{1,2}\s*日?$',
      ).hasMatch(strip(s)) ||
      RegExp(r'^(?:[〇零一二三四五六七八九]{4}年)?[〇零一二三四五六七八九十廿卅]+月[〇零一二三四五六七八九十廿卅]+日$')
          .hasMatch(strip(s));
  bool signatureLine(String s) {
    final value = strip(s);
    if (value.isEmpty ||
        value.length > 24 ||
        RegExp(r'[。！？!?；;，,：:]$').hasMatch(value) ||
        RegExp(
          r'^(?:祝|愿|请|望|盼|保重|谢谢|感谢|再见|晚安|早安|一切|身体|工作|生活|正文|此致|敬礼|我|我们|你|您)',
        ).hasMatch(value)) {
      return false;
    }
    return RegExp(
          r'^(?:爱你的|想你的|牵挂你的|(?:你的)?(?:儿子|女儿|父亲|母亲|爸爸|妈妈|朋友|同学|学生|晚辈|老师|爱人|丈夫|妻子))',
        ).hasMatch(value) ||
        RegExp(
          r"^[\u3400-\u9fff·]{2,4}$|^[A-Za-z][A-Za-z .'-]{1,30}$|(?:敬上|谨上|谨启)$",
        ).hasMatch(value);
  }

  var date = '', signature = '';
  if (indexes.isNotEmpty) {
    final last = indexes.last;
    final right = lines[last].trimLeft().startsWith('>>>');
    if (dateLine(lines[last]) ||
        (right &&
            indexes.length > 1 &&
            lines[indexes[indexes.length - 2]].trimLeft().startsWith('>>>'))) {
      date = strip(lines[last]);
      removed.add(last);
      final signatures = <String>[];
      for (var i = indexes.length - 2; i >= 0 && signatures.length < 2; i--) {
        final index = indexes[i];
        if (!lines[index].trimLeft().startsWith('>>>') &&
            !signatureLine(lines[index])) {
          break;
        }
        signatures.insert(0, strip(lines[index]));
        removed.add(index);
      }
      signature = signatures.join('\n');
    } else if (right || signatureLine(lines[last])) {
      signature = strip(lines[last]);
      removed.add(last);
    }
  }
  return (
    body: [
      for (var i = 0; i < lines.length; i++)
        if (!removed.contains(i)) lines[i],
    ].join('\n').trim(),
    signature: signature,
    date: date,
  );
}
