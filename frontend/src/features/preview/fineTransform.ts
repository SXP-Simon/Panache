import type { Point } from '@/utils/lasso';

// Row-major homography in pixels, with its final coefficient normalized to 1.
export type Quad = [Point, Point, Point, Point];
export type Warp = [number, number, number, number, number, number, number, number];
type Matrix = [...Warp, number];
const identity: Matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1];

function multiply(a: Matrix, b: Matrix): Matrix {
  const [ax, ay, at, bx, by, bt, cx, cy, ct] = a;
  const [dx, dy, dt, ex, ey, et, fx, fy, ft] = b;
  return [
    ax * dx + ay * ex + at * fx,
    ax * dy + ay * ey + at * fy,
    ax * dt + ay * et + at * ft,
    bx * dx + by * ex + bt * fx,
    bx * dy + by * ey + bt * fy,
    bx * dt + by * et + bt * ft,
    cx * dx + cy * ex + ct * fx,
    cx * dy + cy * ey + ct * fy,
    cx * dt + cy * et + ct * ft,
  ];
}

export function mapPoint(matrix: Readonly<Matrix>, x: number, y: number): Point {
  const [a, b, c, d, e, f, g, h, i] = matrix;
  const z = g * x + h * y + i;
  return { x: (a * x + b * y + c) / z, y: (d * x + e * y + f) / z };
}

export function inverseWarp([a, b, c, d, e, f, g, h]: Warp): Matrix {
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

export function affineCorners(
  width: number,
  height: number,
  scale: number,
  cos: number,
  sin: number,
) {
  return [
    [-width / 2, -height / 2],
    [width / 2, -height / 2],
    [width / 2, height / 2],
    [-width / 2, height / 2],
  ].map(([x = 0, y = 0]) => ({ x: scale * (cos * x - sin * y), y: scale * (sin * x + cos * y) }));
}

export function warpFits(warp: Warp, corners: Point[]) {
  if (warp.some((value) => !Number.isFinite(value) || Math.abs(value) > 65535)) return false;
  const inverse = inverseWarp(warp);
  if (Math.abs(warp[0] * inverse[0] + warp[1] * inverse[3] + warp[2] * inverse[6]) < 1e-12)
    return false;
  const projected = corners.map(({ x, y }) => mapPoint([...warp, 1], x, y));
  const span = (points: Point[], axis: 'x' | 'y') =>
    Math.max(...points.map((point) => point[axis])) -
    Math.min(...points.map((point) => point[axis]));
  if (span(projected, 'x') * span(projected, 'y') > 32 * span(corners, 'x') * span(corners, 'y'))
    return false;
  return corners.every(({ x, y }) => {
    if (warp[6] * x + warp[7] * y + 1 < 0.15) return false;
    const point = mapPoint([...warp, 1], x, y);
    return Math.abs(point.x) <= 65535 && Math.abs(point.y) <= 65535;
  });
}

// The same projective map must affect the spacing between glyphs and each glyph's pixels.
export function quadTransform(
  source: Quad,
  target: Quad,
): { origin: Point; matrix: Matrix } | undefined {
  const origin = source[0];
  const local = ([a, b, c, d]: Quad): Quad =>
    [a, b, c, d].map(({ x, y }) => ({ x: x - origin.x, y: y - origin.y })) as Quad;
  const from = squareToQuad(local(source));
  const to = squareToQuad(local(target));
  if (!from || !to) return;
  return { origin, matrix: multiply([...to, 1], inverseWarp(from)) };
}

function squareToQuad([a, b, c, d]: Quad): Warp | undefined {
  const ab = { x: b.x - a.x, y: b.y - a.y },
    bc = { x: c.x - b.x, y: c.y - b.y };
  const cd = { x: d.x - c.x, y: d.y - c.y },
    da = { x: a.x - d.x, y: a.y - d.y };
  const cross = (u: Point, v: Point) => u.x * v.y - u.y * v.x;
  if (Math.min(cross(ab, bc), cross(bc, cd), cross(cd, da), cross(da, ab)) <= 0.01) return;
  const delta = { x: cd.x + ab.x, y: cd.y + ab.y };
  const det = cross(cd, bc);
  const g = cross(cd, delta) / det;
  const h = -cross(delta, bc) / det;
  return [ab.x + g * b.x, d.x - a.x + h * d.x, a.x, ab.y + g * b.y, d.y - a.y + h * d.y, a.y, g, h];
}

export function composeWarp(current: Warp | undefined, offset: Point, transform: Matrix): Warp {
  const { x, y } = offset;
  const centered: Matrix = [1, 0, x, 0, 1, y, 0, 0, 1];
  const restore: Matrix = [1, 0, -x, 0, 1, -y, 0, 0, 1];
  const result = multiply(
    multiply(restore, multiply(transform, centered)),
    current ? [...current, 1] : identity,
  );
  const [a, b, c, d, e, f, g, h, i] = result;
  return [a / i, b / i, c / i, d / i, e / i, f / i, g / i, h / i];
}

export function transformWarp(
  current: Warp | undefined,
  offset: Point,
  angle: number,
  gx: number,
  gy: number,
): Warp {
  const radians = (angle * Math.PI) / 180;
  const cos = Math.cos(radians),
    sin = Math.sin(radians);
  return composeWarp(current, offset, [cos, -sin, 0, sin, cos, 0, gx, gy, 1]);
}
