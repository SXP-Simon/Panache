export type Point = { x: number; y: number };

export function containsPoint(points: readonly Point[], { x, y }: Point) {
  let inside = false;
  let previous = points.at(-1);
  if (!previous) return false;
  for (const next of points) {
    if (
      next.y > y !== previous.y > y &&
      x < next.x + ((y - next.y) * (previous.x - next.x)) / (previous.y - next.y)
    ) {
      inside = !inside;
    }
    previous = next;
  }
  return inside;
}

// Find the largest rectangular grid region fully enclosed by the lasso.
export function enclosedRectangle(points: readonly Point[]) {
  const last = points.at(-1);
  if (points.length < 3 || !last) return null;
  const minX = Math.min(...points.map(({ x }) => x));
  const minY = Math.min(...points.map(({ y }) => y));
  const columns = 64,
    rows = 64;
  const dx = (Math.max(...points.map(({ x }) => x)) - minX) / columns;
  const dy = (Math.max(...points.map(({ y }) => y)) - minY) / rows;
  if (dx <= 0 || dy <= 0) return null;
  const heights = Array.from({ length: columns }, () => 0);
  let best = 0;
  let result: { left: number; top: number; right: number; bottom: number } | null = null;
  for (let row = 0; row < rows; row++) {
    const top = minY + row * dy,
      bottom = top + dy,
      y = (top + bottom) / 2;
    const cuts: number[] = [];
    const edges: [number, number][] = [];
    let previous = last;
    for (const next of points) {
      if (next.y > y !== previous.y > y)
        cuts.push(next.x + ((y - next.y) * (previous.x - next.x)) / (previous.y - next.y));
      if (Math.min(previous.y, next.y) < bottom && Math.max(previous.y, next.y) > top) {
        const from =
          previous.y === next.y
            ? 0
            : Math.min(1, Math.max(0, (top - previous.y) / (next.y - previous.y)));
        const to =
          previous.y === next.y
            ? 1
            : Math.min(1, Math.max(0, (bottom - previous.y) / (next.y - previous.y)));
        const a = previous.x + (next.x - previous.x) * from;
        const b = previous.x + (next.x - previous.x) * to;
        edges.push([Math.min(a, b), Math.max(a, b)]);
      }
      previous = next;
    }
    cuts.sort((a, b) => a - b);
    let cut = 0;
    for (let column = 0; column < columns; column++) {
      const left = minX + column * dx,
        right = left + dx;
      while ((cuts[cut] ?? Infinity) <= left) cut++;
      heights[column] =
        cut % 2 && !edges.some(([a, b]) => a < right && b > left) ? (heights[column] ?? 0) + 1 : 0;
    }
    const stack: number[] = [];
    for (let column = 0; column <= columns; column++) {
      const current = heights[column] ?? 0;
      let previous = stack.at(-1);
      while (previous !== undefined && (heights[previous] ?? 0) > current) {
        const height = heights[previous] ?? 0;
        stack.pop();
        previous = stack.at(-1);
        const first = (stack.at(-1) ?? -1) + 1;
        if (height * (column - first) <= best) continue;
        best = height * (column - first);
        result = {
          left: minX + first * dx,
          right: minX + column * dx,
          top: bottom - height * dy,
          bottom,
        };
      }
      stack.push(column);
    }
  }
  return result;
}

// Sample in screen pixels to keep interactive polygon work independent of image dimensions.
export function appendPoint(points: Point[], point: Point, minimum: number) {
  const last = points.at(-1);
  if (!last || Math.hypot(last.x - point.x, last.y - point.y) >= minimum) {
    if (points.length === 2048) {
      const reduced = points.filter((_, index) => index % 2 === 0);
      points.splice(0, points.length, ...reduced);
      points.length = 1024;
    }
    points.push(point);
  }
}
