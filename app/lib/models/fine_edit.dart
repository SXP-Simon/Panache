import 'dart:convert';
import 'dart:typed_data';

typedef FineRange = ({int start, int end});

class FineGlyph {
  const FineGlyph(
    this.id,
    this.x,
    this.y,
    this.width,
    this.height,
    this.ax,
    this.ay,
    this.baseline,
    this.source,
  );

  final int id, x, y, width, height, ax, ay, baseline;
  final FineRange? source;

  factory FineGlyph.fromJson(Object? data, Object? source) {
    if (data is! List || data.length != 8 || data.any((v) => v is! int)) {
      throw const FormatException('Invalid fine edit glyph');
    }
    final v = data.cast<int>();
    if (v[0] < 0 || v[3] <= 0 || v[4] <= 0 || v[5] < 0 || v[6] < 0) {
      throw const FormatException('Invalid fine edit bounds');
    }
    final range =
        source is List &&
            source.length == 2 &&
            source[0] is int &&
            source[1] is int
        ? (start: source[0] as int, end: source[1] as int)
        : null;
    return FineGlyph(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], range);
  }
}

class FinePage {
  const FinePage(this.key, this.atlas, this.glyphs);
  final String key;
  final Uint8List atlas;
  final List<FineGlyph> glyphs;

  factory FinePage.fromJson(Map<String, dynamic> json) {
    final items = json['glyphs'] as List;
    final ranges = json['source_ranges'] as List?;
    final key = json['key'] as String;
    if (!_validKey(key) || (ranges != null && ranges.length != items.length)) {
      throw const FormatException('Invalid fine edit page');
    }
    final glyphs = [
      for (var i = 0; i < items.length; i++)
        FineGlyph.fromJson(items[i], ranges?[i]),
    ];
    if (glyphs.map((item) => item.id).toSet().length != glyphs.length) {
      throw const FormatException('Duplicate glyph IDs');
    }
    return FinePage(
      key,
      base64Decode(json['atlas'] as String),
      List.unmodifiable(glyphs),
    );
  }
}

typedef FineAdjustment = ({
  int id,
  int dx,
  int dy,
  int scale,
  int angle,
  int opacity,
  int? color,
  int thickness,
  int softness,
});

FineAdjustment defaultFineAdjustment(int id) => (
  id: id,
  dx: 0,
  dy: 0,
  scale: 100,
  angle: 0,
  opacity: 100,
  color: null,
  thickness: 0,
  softness: 0,
);

bool _validKey(String key) => RegExp(r'^[0-9a-f]{64}$').hasMatch(key);

class FineEdits {
  FineEdits(this.key, Map<int, FineAdjustment> glyphs)
    : glyphs = Map.unmodifiable(glyphs);
  final String key;
  final Map<int, FineAdjustment> glyphs;

  factory FineEdits.fromJson(Map<String, dynamic> json) {
    final key = json['key'] as String;
    final data = json['glyphs'] as List;
    if (!_validKey(key) || data.length > 10000) {
      throw const FormatException('Invalid fine edits');
    }
    final result = <int, FineAdjustment>{};
    for (final row in data) {
      final value = row as Map<String, dynamic>;
      final rgb = value['color'] as List?;
      if (rgb != null &&
          (rgb.length != 3 || rgb.any((c) => c is! int || c < 0 || c > 255))) {
        throw const FormatException('Invalid fine edit color');
      }
      final edit = (
        id: value['id'] as int,
        dx: value['dx'] as int,
        dy: value['dy'] as int,
        scale: value['scale'] as int,
        angle: value['angle'] as int,
        opacity: value['opacity'] as int,
        thickness: value['thickness'] as int? ?? 0,
        softness: value['softness'] as int? ?? 0,
        color: rgb == null
            ? null
            : 0xff000000 +
                  (rgb[0] as int) * 65536 +
                  (rgb[1] as int) * 256 +
                  (rgb[2] as int),
      );
      if (edit.id < 0 ||
          edit.dx.abs() > 65535 ||
          edit.dy.abs() > 65535 ||
          edit.scale < 50 ||
          edit.scale > 200 ||
          edit.angle.abs() > 45 ||
          edit.opacity < 0 ||
          edit.opacity > 100 ||
          edit.thickness.abs() > 20 ||
          edit.softness.abs() > 20) {
        throw const FormatException('Invalid fine adjustment');
      }
      result[edit.id] = edit;
    }
    return FineEdits(key, result);
  }

  Map<String, Object> toJson() => {
    'key': key,
    'glyphs': [
      for (final edit in glyphs.values)
        {
          'id': edit.id,
          'dx': edit.dx,
          'dy': edit.dy,
          'scale': edit.scale,
          'angle': edit.angle,
          'opacity': edit.opacity,
          if (edit.thickness != 0) 'thickness': edit.thickness,
          if (edit.softness != 0) 'softness': edit.softness,
          'color': edit.color == null
              ? null
              : [
                  edit.color! >> 16 & 255,
                  edit.color! >> 8 & 255,
                  edit.color! & 255,
                ],
        },
    ],
  };
}
