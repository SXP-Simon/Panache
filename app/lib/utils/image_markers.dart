/// A concrete illustration occurrence, including legacy img: references.
class IllustrationMarker {
  const IllustrationMarker(this.id, this.start, this.end, this.scale);
  final String id;
  final int start, end, scale;
  String resized(int width) => '![插图 $id|$width%]';
}

List<IllustrationMarker> illustrationMarkers(String text) {
  final pattern = RegExp(
    r'!\[(?:插图[ \t]*[#:_-]?[ \t]*(\d+)(?:\|([^\]]+))?)\](?!\()|!\[([^\]]*)\]\(img:?_?(\d+)\)',
  );
  return [
    for (final m in pattern.allMatches(text))
      IllustrationMarker(
        m[1] ?? m[4]!,
        m.start,
        m.end,
        (int.tryParse(
                  (m[2] ?? m[3]?.split('|').last ?? '50')
                      .replaceAll('%', '')
                      .trim(),
                ) ??
                50)
            .clamp(10, 700),
      ),
  ];
}

String nextIllustrationId(Map<String, String> images, String text) {
  final reserved = {
    ...images.keys,
    ...illustrationMarkers(text).map((m) => m.id),
  };
  var next = 1;
  while (reserved.contains('$next')) {
    next++;
  }
  return '$next';
}
