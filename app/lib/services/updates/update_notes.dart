/// Compact user-facing changes; installation guides stay on the release page.
List<String> summarizeReleaseNotes(String source) {
  final result = <String>[];
  for (final line in source.split('\n')) {
    if (RegExp(
      r'^#{1,6}\s*(?:下载|安装|校验|Download|Install|Assets|Checksums|macOS|Electron|Flutter\s*客户端)',
      caseSensitive: false,
    ).hasMatch(line.trim())) {
      break;
    }
    final match = RegExp(r'^\s*[-*+]\s+(.+)').firstMatch(line);
    if (match == null) continue;
    var text = match
        .group(1)!
        .replaceAll(RegExp(r'\s*\(?\[[a-f0-9]{7,40}\]\([^)]*\)\)?'), '')
        .replaceAll(RegExp(r'^\*\*[^*]+\*\*:?\s*'), '')
        .replaceAll(RegExp(r'^[a-z][a-z0-9_/.-]*:\s*'), '')
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\([^)]*\)'),
          (match) => match.group(1)!,
        )
        .replaceAll(RegExp(r'[`*_]'), '')
        .trim();
    if (text.isEmpty || text.contains('https://')) continue;
    if (text.length > 140) text = '${text.substring(0, 140)}…';
    if (!result.contains(text)) result.add(text);
    if (result.length == 5) break;
  }
  return result;
}
