import 'dart:math' as math;
import 'dart:ui';

typedef FineWarp = (
  double,
  double,
  double,
  double,
  double,
  double,
  double,
  double,
);

List<double> coefficients(FineWarp warp) => [
  warp.$1,
  warp.$2,
  warp.$3,
  warp.$4,
  warp.$5,
  warp.$6,
  warp.$7,
  warp.$8,
];

FineWarp readWarp(List<double> values) => (
  values[0],
  values[1],
  values[2],
  values[3],
  values[4],
  values[5],
  values[6],
  values[7],
);

const _identity = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];

List<double> _multiply(List<double> left, List<double> right) => [
  for (var row = 0; row < 9; row += 3)
    for (var col = 0; col < 3; col++)
      left[row] * right[col] +
          left[row + 1] * right[col + 3] +
          left[row + 2] * right[col + 6],
];

Offset mapFinePoint(List<double> m, Offset at) {
  final z = m[6] * at.dx + m[7] * at.dy + m[8];
  return Offset(
    (m[0] * at.dx + m[1] * at.dy + m[2]) / z,
    (m[3] * at.dx + m[4] * at.dy + m[5]) / z,
  );
}

List<double> inverseFineWarp(FineWarp warp) {
  final (a, b, c, d, e, f, g, h) = warp;
  return [
    e - f * h,
    c * h - b,
    b * f - c * e,
    f * g - d,
    a - c * g,
    c * d - a * f,
    d * h - e * g,
    b * g - a * h,
    a * e - b * d,
  ];
}

List<Offset> fineCorners(
  int width,
  int height,
  double scale,
  double cos,
  double sin,
) => [
  for (final x in [-width / 2, width / 2])
    for (final y in [-height / 2, height / 2])
      Offset(scale * (cos * x - sin * y), scale * (sin * x + cos * y)),
];

bool fineWarpFits(FineWarp warp, List<Offset> corners) {
  final matrix = [...coefficients(warp), 1.0];
  if (matrix.any((value) => !value.isFinite || value.abs() > 65535)) {
    return false;
  }
  final inverse = inverseFineWarp(warp);
  if ((matrix[0] * inverse[0] + matrix[1] * inverse[3] + matrix[2] * inverse[6])
          .abs() <
      1e-12) {
    return false;
  }
  final projected = [for (final point in corners) mapFinePoint(matrix, point)];
  double span(Iterable<double> values) =>
      values.reduce(math.max) - values.reduce(math.min);
  if (span(projected.map((p) => p.dx)) * span(projected.map((p) => p.dy)) >
      32 * span(corners.map((p) => p.dx)) * span(corners.map((p) => p.dy))) {
    return false;
  }
  return corners.every((point) {
    if (warp.$7 * point.dx + warp.$8 * point.dy + 1 < .15) return false;
    final mapped = mapFinePoint(matrix, point);
    return mapped.dx.abs() <= 65535 && mapped.dy.abs() <= 65535;
  });
}

// Apply one map to the whole selection, including the spaces between glyphs.
({Offset origin, List<double> matrix})? fineQuadTransform(
  List<Offset> source,
  List<Offset> target,
) {
  final origin = source.first;
  final from = _squareToQuad([for (final point in source) point - origin]);
  final to = _squareToQuad([for (final point in target) point - origin]);
  if (from == null || to == null) return null;
  return (
    origin: origin,
    matrix: _multiply([...coefficients(to), 1.0], inverseFineWarp(from)),
  );
}

FineWarp? _squareToQuad(List<Offset> corners) {
  final a = corners[0], b = corners[1], c = corners[2], d = corners[3];
  final ab = b - a, bc = c - b, cd = d - c, da = a - d;
  double cross(Offset u, Offset v) => u.dx * v.dy - u.dy * v.dx;
  if ([
    cross(ab, bc),
    cross(bc, cd),
    cross(cd, da),
    cross(da, ab),
  ].any((v) => v <= .01)) {
    return null;
  }
  final delta = ab + cd;
  final det = cross(cd, bc);
  final g = cross(cd, delta) / det;
  final h = -cross(delta, bc) / det;
  return (
    ab.dx + g * b.dx,
    d.dx - a.dx + h * d.dx,
    a.dx,
    ab.dy + g * b.dy,
    d.dy - a.dy + h * d.dy,
    a.dy,
    g,
    h,
  );
}

FineWarp transformFineWarp(
  FineWarp? warp,
  Offset offset,
  int angle,
  double gx,
  double gy,
) {
  final radians = angle * math.pi / 180;
  final cos = math.cos(radians), sin = math.sin(radians);
  return composeFineWarp(warp, offset, [
    cos,
    -sin,
    0.0,
    sin,
    cos,
    0.0,
    gx,
    gy,
    1.0,
  ]);
}

FineWarp composeFineWarp(
  FineWarp? warp,
  Offset offset,
  List<double> transform,
) {
  final x = offset.dx, y = offset.dy;
  final centered = [1.0, 0.0, x, 0.0, 1.0, y, 0.0, 0.0, 1.0];
  final restore = [1.0, 0.0, -x, 0.0, 1.0, -y, 0.0, 0.0, 1.0];
  final result = _multiply(
    _multiply(restore, _multiply(transform, centered)),
    warp == null ? _identity : [...coefficients(warp), 1.0],
  );
  return readWarp([for (final value in result.take(8)) value / result[8]]);
}
