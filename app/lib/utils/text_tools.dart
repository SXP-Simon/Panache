import 'math_segments.dart';
import 'image_data.dart';
import 'image_markers.dart';
import 'markdown_literals.dart';

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

String _replaceEmbeddedImages(
  String text,
  String? Function(RegExpMatch match, int end) replacement,
) {
  final opening = RegExp(r'!\[([^\]]*)\]\((data:image/[^;)\s]+;base64,)');
  final result = StringBuffer();
  var cursor = 0;
  for (final match in opening.allMatches(text)) {
    if (match.start < cursor) continue;
    final end = text.indexOf(')', match.end);
    if (end < 0) break;
    final value = replacement(match, end);
    if (value == null) continue;
    result
      ..write(text.substring(cursor, match.start))
      ..write(value);
    cursor = end + 1;
  }
  if (cursor == 0) return text;
  result.write(text.substring(cursor));
  return result.toString();
}

String collapseImages(String text, Map<String, String> images) =>
    _replaceEmbeddedImages(text, (match, end) {
      final payload = compactImagePayload(text.substring(match.end, end));
      if (payload == null) return null;
      final data = '${match[2]}$payload';
      final existing = images.entries.where((e) => e.value == data).firstOrNull;
      final id = existing?.key ?? nextIllustrationId(images, text);
      images[id] = data;
      final alt = match[1]!;
      final scale = alt.contains('|') ? '|${alt.split('|').last}' : '';
      return '![插图 $id$scale]';
    });

// Literal ranges from the shared scanner keep their original spelling unless replaced.
String _replaceSegments(String text, String? Function(String) replacement) {
  final out = StringBuffer();
  var cursor = 0;
  for (final segment in scanMathSegments(text)) {
    final value = replacement(text.substring(segment.start, segment.end));
    if (value == null) continue;
    out.write(text.substring(cursor, segment.start));
    out.write(value);
    cursor = segment.end;
  }
  if (cursor == 0) return text;
  out.write(text.substring(cursor));
  return out.toString();
}

String cleanMarkdown(
  String text, {
  String tableMode = 'latex',
  bool english = false,
  String Function(String)? transformMath,
}) {
  const quotedStart = '$markdownTokenStart\uFDD1';
  var s = text
      .replaceAll(markdownTokenStart, quotedStart)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final code = protectMarkdownCode(s, inline: false);
  s = code.text;
  final protected = MarkdownPlaceholders('${markdownTokenStart}HW', '\uE101');
  final scriptStars = MarkdownPlaceholders(
    '${markdownTokenStart}HWSTAR',
    '\uE101',
  );

  // A diagram can contain pipes and Markdown-looking labels. Mask its entire
  // source before table recognition so an unsupported diagram stays editable.
  s = _replaceSegments(
    s,
    (source) =>
        source.contains(r'\begin{circuitikz}') ? protected.save(source) : null,
  );

  if (tableMode == 'latex') {
    s = _convertMarkdownTables(s, protected.save);
  }

  s = _replaceSegments(s, (source) {
    // Links and images retain the existing Markdown extraction rules.
    if (source.startsWith('![') ||
        source.startsWith('[') ||
        source.startsWith('`')) {
      return null;
    }
    final fenced = RegExp(r'^(`{3,}|~{3,})[^\n]*\n([\s\S]*?)\1$')
        .firstMatch(source);
    return protected.save(fenced?[2] ?? source);
  });
  final bodyCode = protectMarkdownCode(s);
  s = bodyCode.text;
  // Converted script stars must not become Markdown emphasis on a second cleanup.
  s = s.replaceAllMapped(
    RegExp(r'[_^](?:\(\*\)|\{\*\}|\*)'),
    (match) => scriptStars.save(match[0]!),
  );
  final bareMath = StringBuffer();
  var cursor = 0;
  for (final match in RegExp(r'\\left\b').allMatches(s)) {
    if (match.start < cursor) continue;
    final end = bareDelimiterEnd(s, match.start);
    if (end <= match.start) continue;
    bareMath.write(s.substring(cursor, match.start));
    bareMath.write(protected.save(s.substring(match.start, end)));
    cursor = end;
  }
  bareMath.write(s.substring(cursor));
  final unprotectedImages = bareMath.toString();
  s = _replaceEmbeddedImages(
    unprotectedImages,
    (match, end) =>
        protected.save(unprotectedImages.substring(match.start, end + 1)),
  );
  s = s.replaceAllMapped(
    RegExp(
      r'!\[[^\]]*\]\(img:?_?\d+\)|!\[插图(?:[ \t]*[#:_-]?[ \t]*\d+)?(?:\|[^\]]+)?\](?!\()',
    ),
    (m) {
      return protected.save(m[0]!);
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
      .replaceAll(
        RegExp(
          r'''</?(?:p|div|span|strong|em|b|i|u|s|del|strike|sub|sup|pre|code|blockquote|ul|ol|li|h[1-6]|table|thead|tbody|tr|td|th)(?:\s+(?:class|id|style|title|lang|dir)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s<>]+))*\s*/?>''',
          caseSensitive: false,
        ),
        '',
      );
  s = s.replaceAllMapped(
    RegExp(r'```[^\n]*\n([\s\S]*?)```|~~~[^\n]*\n([\s\S]*?)~~~'),
    (m) => m[1] ?? m[2]!,
  );
  s = s.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1]!);
  s = stripMarkdownLinks(s);
  s = _cleanLines(s, tableMode, english);
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
  s = protected.restore(s);
  s = s
      .split('\n')
      .where((line) => line.trim().isNotEmpty && line.trim() != '---')
      .join('\n')
      .trim();
  // Keep literal code masked until both cleanup stages have finished.
  s = transformMath?.call(s) ?? s;
  s = scriptStars.restore(s);
  return code
      .restore(bodyCode.restore(s))
      .replaceAll(quotedStart, markdownTokenStart);
}

String _cleanLines(String source, String tableMode, bool english) {
  final output = <String>[], table = <String>[];
  void flush() {
    if (table.isEmpty) return;
    output.addAll(_formatTable(table, tableMode, english));
    table.clear();
  }

  var listContinuation = false;
  for (var line in source.split('\n')) {
    if (tableMode != 'latex' && RegExp(r'^\s*\|.*\|\s*$').hasMatch(line)) {
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
  return output.join('\n');
}

Iterable<String> _formatTable(
  List<String> table,
  String tableMode,
  bool english,
) {
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
  if (rows.isEmpty) return const [];
  if (tableMode == 'list' && rows.length > 1) return _listRows(rows, english);
  if (tableMode == 'aligned') return _alignedRows(rows);
  return rows.map((row) => row.join(tableMode == 'raw_pipe' ? ' | ' : '  '));
}

Iterable<String> _listRows(List<List<String>> rows, bool english) sync* {
  final headers = rows.first;
  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    final fields = [
      for (var j = 1; j < row.length; j++)
        '${j < headers.length ? headers[j] : '${english ? 'Column' : '列'}${j + 1}'}: ${row[j].isEmpty ? '-' : row[j]}',
    ];
    yield '$i. ${headers.first}: ${row.first}${fields.isEmpty ? '' : ' (${fields.join('; ')})'}';
  }
}

Iterable<String> _alignedRows(List<List<String>> rows) {
  int width(String value) =>
      value.runes.fold(0, (a, b) => a + (b > 255 ? 2 : 1));
  final widths = <int>[];
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      final size = width(row[i]);
      if (i == widths.length) {
        widths.add(size);
      } else if (size > widths[i]) {
        widths[i] = size;
      }
    }
  }
  return rows.map(
    (r) => [
      for (var i = 0; i < r.length; i++)
        r[i] + ' ' * (widths[i] - width(r[i]) + 2),
    ].join().trimRight(),
  );
}

// Markdown 表格仅在完整分隔行后识别；不完整或超宽数据保持原文。
String _convertMarkdownTables(String source, String Function(String) protect) {
  final lines = source.split('\n');
  final output = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final first = _tableCells(lines[i]);
    final separator = i + 1 < lines.length ? _tableCells(lines[i + 1]) : null;
    if (first == null ||
        separator == null ||
        first.length != separator.length ||
        !separator.every(
          (cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell.trim()),
        )) {
      output.add(lines[i]);
      continue;
    }
    final rows = <List<String>>[first];
    var end = i + 2;
    var valid = first.length <= 32;
    while (end < lines.length) {
      final row = _tableCells(lines[end]);
      if (row == null) break;
      if (row.length > first.length) valid = false;
      rows.add([...row, for (var n = row.length; n < first.length; n++) '']);
      end++;
    }
    if (rows.length > 32 ||
        rows.length < 2 ||
        lines.sublist(i, end).fold<int>(0, (sum, line) => sum + line.length) >
            16000) {
      valid = false;
    }
    if (!valid) {
      output.add(protect(lines.sublist(i, end).join('\n')));
    } else {
      final body = rows
          .map((row) => row.map(_tableLatexCell).join(' & '))
          .join(
            r' \\ \hline'
            '\n',
          );
      final latex =
          '\\[\n\\begin{array}{|${List.filled(first.length, 'c').join('|')}|}\n\\hline\n$body'
          r' \\ \hline'
          '\n\\end{array}\n\\]';
      output.add(
        protect(
          latex.length <= 16000 ? latex : lines.sublist(i, end).join('\n'),
        ),
      );
    }
    i = end - 1;
  }
  return output.join('\n');
}

List<String>? _tableCells(String line) {
  final value = line.trim();
  if (value.isEmpty || value.startsWith('⟦')) return null;
  final cells = <String>[];
  final cell = StringBuffer();
  var ticks = 0;
  var dollar = false;
  var paren = false;
  var split = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (char == '\\' && i + 1 < value.length) {
      final next = value[i + 1];
      if (next == '(' && ticks == 0 && !dollar) paren = true;
      if (next == ')' && ticks == 0 && !dollar) paren = false;
      cell.write(char);
      cell.write(next);
      i++;
      continue;
    }
    if (char == '`') {
      var count = 1;
      while (i + count < value.length && value[i + count] == '`') {
        count++;
      }
      ticks = ticks == count
          ? 0
          : ticks == 0
          ? count
          : ticks;
      cell.write('`' * count);
      i += count - 1;
      continue;
    }
    if (char == r'$' && ticks == 0 && !paren) dollar = !dollar;
    if (char == '|' && ticks == 0 && !dollar && !paren) {
      cells.add(cell.toString().trim());
      cell.clear();
      split = true;
    } else {
      cell.write(char);
    }
  }
  cells.add(cell.toString().trim());
  if (!split) return null;
  if (value.startsWith('|')) cells.removeAt(0);
  if (value.endsWith('|') && cells.last.isEmpty) cells.removeLast();
  return cells.isEmpty ? null : cells;
}

String _tableLatexCell(String cell) {
  // Clean paired decorations before splitting a cell into text and formulas.
  final saved = MarkdownPlaceholders('${markdownTokenStart}CELL', '\uE131');
  final masked = _replaceSegments(cell, saved.save);
  cell = saved.restore(cleanMarkdown(masked, tableMode: 'clean'));
  final output = StringBuffer();
  var cursor = 0;
  for (final segment in scanMathSegments(cell)) {
    output.write(_tableText(cell.substring(cursor, segment.start)));
    final value = cell.substring(segment.start, segment.end);
    if (value.startsWith(r'\(') && value.endsWith(r'\)')) {
      output.write(value.substring(2, value.length - 2));
    } else if (value.startsWith(r'$$') && value.endsWith(r'$$')) {
      output.write(value.substring(2, value.length - 2));
    } else if (value.startsWith(r'$') &&
        value.endsWith(r'$') &&
        value.length > 1) {
      output.write(value.substring(1, value.length - 1));
    } else {
      output.write(_tableText(value));
    }
    cursor = segment.end;
  }
  output.write(_tableText(cell.substring(cursor)));
  return output.toString();
}

String _tableText(String value) {
  if (value.isEmpty) return '';
  final code = protectMarkdownCode(value);
  value = stripMarkdownLinks(code.text).replaceAll(r'\|', '|');
  for (final marker in ['***', '___', '**', '__', '~~']) {
    value = value.replaceAllMapped(
      RegExp('${RegExp.escape(marker)}(.+?)${RegExp.escape(marker)}'),
      (match) => match[1]!,
    );
  }
  value = value.replaceAllMapped(
    RegExp(r'(^|[^\w*])\*([^\s*][^*\n]*?)\*(?=[^\w*]|$)'),
    (match) => '${match[1]}${match[2]}',
  );
  value = code.restore(value);
  const escapes = <String, String>{
    '\\': r'\textbackslash{}',
    '{': r'\{',
    '}': r'\}',
    '%': r'\%',
    '&': r'\&',
    '#': r'\#',
    '_': r'\_',
    r'$': r'\$',
    '^': r'\textasciicircum{}',
    '~': r'\textasciitilde{}',
  };
  return '\\text{${value.split('').map((c) => escapes[c] ?? c).join()}}';
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
