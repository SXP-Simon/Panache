import { useEffect, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent, PointerEvent } from 'react';
import { defaultAdjustment } from './fineEditModel';
import type { Adjustment, Adjustments, Glyph } from './fineEditModel';
import { appendPoint, containsPoint } from '@/utils/lasso';
import {
  affineCorners,
  composeWarp,
  quadTransform,
  transformWarp,
  warpFits,
} from './fineTransform';
import type { Quad, Warp } from './fineTransform';
import { hitGlyph, pose, union } from './fineRaster';
import type { Bounds } from './fineRaster';

type Point = { x: number; y: number };
type PerspectiveFrame = { points: Quad; items: Glyph[]; edits: (Adjustment | undefined)[] };
type CornerDrag = {
  pointer: number;
  index: number;
  start: Point;
  frame: PerspectiveFrame;
  latest?: { points: Quad; changes: Adjustment[] };
};
type Gesture = {
  id: number;
  start: Point;
  screen: Point;
  moved: boolean;
  mode: 'move' | 'box' | 'lasso' | 'tap';
  path?: Point[];
  glyphs: Glyph[];
  hit?: Glyph;
  append: boolean;
};
const selectionBox = (a: Point, b: Point): Bounds => ({
  left: Math.min(a.x, b.x),
  right: Math.max(a.x, b.x),
  top: Math.min(a.y, b.y),
  bottom: Math.max(a.y, b.y),
});
const inside = (p: Point, box: Bounds, slop = 0) =>
  p.x >= box.left - slop &&
  p.x <= box.right + slop &&
  p.y >= box.top - slop &&
  p.y <= box.bottom + slop;

export function useFineSelection({
  glyphs,
  edits,
  size,
  commit,
  history,
  sourceIds,
  clearSource,
}: {
  glyphs: Glyph[];
  edits: Adjustments;
  size: { width: number; height: number };
  commit: (changes: Adjustment[]) => void;
  history: (direction: 'undo' | 'redo') => void;
  sourceIds: ReadonlySet<number> | undefined;
  clearSource: () => void;
}) {
  const [localIds, setIds] = useState<ReadonlySet<number>>(new Set());
  const ids = sourceIds ?? localIds;
  const [box, setBox] = useState<Bounds>();
  const [lasso, setLasso] = useState<Point[]>([]);
  const [frames, setFrames] = useState<PerspectiveFrame[]>([]);
  const [cornerDraft, setCornerDraft] = useState<Quad>();
  const cornerDrag = useRef<CornerDrag>(null);
  const [draft, setDraft] = useState<Adjustment[]>([]);
  const [snap, setSnap] = useState(true);
  const [touchTool, setTouchTool] = useState<'pan' | 'box' | 'lasso' | 'move' | 'perspective'>(
    'pan',
  );
  const gesture = useRef<Gesture>(null);
  const draftRef = useRef<Adjustment[]>([]);
  const frame = useRef(0);
  useEffect(() => () => cancelAnimationFrame(frame.current), []);
  const selected = useMemo(() => glyphs.filter(([id]) => ids.has(id)), [glyphs, ids]);
  const displayed = useMemo(
    () =>
      draft.length ? new Map([...edits, ...draft.map((edit) => [edit.id, edit] as const)]) : edits,
    [draft, edits],
  );

  const perspective = touchTool === 'perspective' && perspectiveFrame();
  const quad = perspective ? (cornerDraft ?? perspective.points) : undefined;

  function local(event: PointerEvent<SVGSVGElement>): Point {
    const bounds = event.currentTarget.getBoundingClientRect();
    return {
      x: ((event.clientX - bounds.left) * size.width) / bounds.width,
      y: ((event.clientY - bounds.top) * size.height) / bounds.height,
    };
  }

  function position(glyph: Glyph): Adjustment {
    return edits.get(glyph[0]) ?? { id: glyph[0], ...defaultAdjustment };
  }

  function select(items: Glyph[], append = false) {
    clearSource();
    setIds(() => {
      const next = new Set(append ? ids : []);
      for (const [id] of items) {
        if (append && next.has(id)) next.delete(id);
        else next.add(id);
      }
      return next;
    });
  }

  function onPointerDown(event: PointerEvent<SVGSVGElement>) {
    if (event.button !== 0 || gesture.current || cornerDrag.current) return;
    if (event.pointerType === 'touch' && !event.isPrimary) return;
    const start = local(event);
    if (touchTool === 'perspective') {
      if (!perspective) return;
      const bounds = event.currentTarget.getBoundingClientRect();
      const distances = perspective.points.map(({ x, y }) =>
        Math.hypot(
          ((x - start.x) * bounds.width) / size.width,
          ((y - start.y) * bounds.height) / size.height,
        ),
      );
      const nearest = Math.min(...distances);
      if (nearest > (event.pointerType === 'touch' ? 21 : 14)) return;
      event.preventDefault();
      event.currentTarget.focus({ preventScroll: true });
      event.currentTarget.setPointerCapture(event.pointerId);
      cornerDrag.current = {
        pointer: event.pointerId,
        index: distances.indexOf(nearest),
        start,
        frame: perspective,
      };
      return;
    }
    let unit: Glyph | undefined;
    for (let i = glyphs.length - 1; i >= 0; i -= 1) {
      const glyph = glyphs[i];
      if (
        glyph &&
        hitGlyph(glyph, edits.get(glyph[0]), start, event.pointerType === 'touch' ? 3 : 0)
      ) {
        unit = glyph;
        break;
      }
    }
    const append = event.shiftKey;
    const group = boundsOf(selected);
    const movingGroup = !append && group && inside(start, group) && (!unit || ids.has(unit[0]));
    // Touch has an explicit gesture tool so scrolling doesn't accidentally move ink.
    if (event.pointerType === 'touch' && touchTool === 'pan') {
      gesture.current = {
        id: event.pointerId,
        start,
        screen: { x: event.clientX, y: event.clientY },
        moved: false,
        mode: 'tap',
        glyphs: [],
        ...(unit ? { hit: unit } : {}),
        append: false,
      };
      return;
    }
    gesture.current = {
      id: event.pointerId,
      start,
      screen: { x: event.clientX, y: event.clientY },
      moved: false,
      path: [start],
      mode:
        touchTool === 'lasso' || touchTool === 'box'
          ? touchTool
          : event.pointerType === 'touch'
            ? touchTool === 'move'
              ? 'move'
              : 'box'
            : !append && (movingGroup || unit)
              ? 'move'
              : 'box',
      glyphs:
        movingGroup || (event.pointerType === 'touch' && touchTool === 'move')
          ? selected
          : unit
            ? [unit]
            : [],
      ...(unit ? { hit: unit } : {}),
      append,
    };
    event.currentTarget.focus({ preventScroll: true });
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function movement(items: Glyph[], dx: number, dy: number, snapToLine: boolean) {
    const region = boundsOf(items);
    const anchor = items[0];
    if (!region || !anchor) return [];
    if (snapToLine && dy !== 0) {
      const baseline = anchor[7] + position(anchor).dy;
      const target = baseline + dy;
      const candidates = glyphs.map((glyph) => glyph[7]);
      const closest = candidates.reduce(
        (best, line) => (Math.abs(line - target) < Math.abs(best - target) ? line : best),
        anchor[7],
      );
      const threshold = Math.min(12, Math.max(3, anchor[4] / 4));
      if (Math.abs(closest - target) <= threshold) dy = closest - baseline;
    }
    // Keep the original overflow allowance for natural strokes at the paper edge.
    dx = Math.round(
      Math.min(Math.max(0, size.width - region.right), Math.max(Math.min(0, -region.left), dx)),
    );
    dy = Math.round(
      Math.min(Math.max(0, size.height - region.bottom), Math.max(Math.min(0, -region.top), dy)),
    );
    return items.map((glyph) => {
      const edit = position(glyph);
      return { ...edit, dx: edit.dx + dx, dy: edit.dy + dy };
    });
  }

  function boundsOf(items: Glyph[]) {
    let bounds: Bounds | undefined;
    for (const glyph of items) {
      const region = pose(glyph, edits.get(glyph[0]));
      bounds = bounds ? union(bounds, region) : region;
    }
    return bounds;
  }

  function perspectiveFrame(): PerspectiveFrame | undefined {
    const remembered = frames.find(
      (frame) =>
        frame.items.length === selected.length &&
        frame.items.every((glyph, index) => {
          const before = frame.edits[index];
          const now = edits.get(glyph[0]);
          return (
            glyph === selected[index] &&
            before?.warp === now?.warp &&
            (before?.scale ?? 100) === (now?.scale ?? 100) &&
            (before?.angle ?? 0) === (now?.angle ?? 0) &&
            (before?.dx ?? 0) === (now?.dx ?? 0) &&
            (before?.dy ?? 0) === (now?.dy ?? 0)
          );
        }),
    );
    if (remembered) return remembered;
    const box = boundsOf(selected);
    if (!box) return;
    return {
      items: selected,
      edits: selected.map(([id]) => edits.get(id)),
      points: [
        { x: box.left, y: box.top },
        { x: box.right, y: box.top },
        { x: box.right, y: box.bottom },
        { x: box.left, y: box.bottom },
      ],
    };
  }

  function cornerChange(frame: PerspectiveFrame, index: number, dx: number, dy: number) {
    const anchor = frame.points[index];
    if (!anchor) return;
    const points: Quad = [...frame.points];
    const limit = (value: number, previous: number, extent: number) =>
      Math.max(Math.min(0, previous), Math.min(value, Math.max(extent, previous)));
    const target = {
      x: limit(anchor.x + dx, anchor.x, size.width),
      y: limit(anchor.y + dy, anchor.y, size.height),
    };
    if (Math.hypot(target.x - anchor.x, target.y - anchor.y) < 1e-6) return { points, changes: [] };
    points[index] = target;
    const map = quadTransform(frame.points, points);
    if (!map) return;
    const changes = project(frame.items, (edit, p) =>
      composeWarp(edit.warp, { x: p.cx - map.origin.x, y: p.cy - map.origin.y }, map.matrix),
    );
    return changes ? { points, changes } : undefined;
  }

  function applyCorner(frame: PerspectiveFrame, result: { points: Quad; changes: Adjustment[] }) {
    if (!result.changes.length) return;
    setFrames((previous) => [
      { points: result.points, items: frame.items, edits: result.changes },
      frame,
      ...previous.slice(0, 48),
    ]);
    commit(result.changes);
  }

  function onPointerMove(event: PointerEvent<SVGSVGElement>) {
    const drag = cornerDrag.current;
    if (drag?.pointer === event.pointerId) {
      const point = local(event);
      const result = cornerChange(
        drag.frame,
        drag.index,
        point.x - drag.start.x,
        point.y - drag.start.y,
      );
      if (!result) return;
      drag.latest = result;
      cancelAnimationFrame(frame.current);
      frame.current = requestAnimationFrame(() => {
        setCornerDraft(result.points);
        setDraft(result.changes);
      });
      return;
    }
    const active = gesture.current;
    if (!active || active.id !== event.pointerId) return;
    if (
      !active.moved &&
      Math.hypot(event.clientX - active.screen.x, event.clientY - active.screen.y) < 4
    )
      return;
    const point = local(event);
    cancelAnimationFrame(frame.current);
    if (active.mode === 'tap') {
      active.moved = true;
      return;
    }
    if (active.mode === 'box') {
      frame.current = requestAnimationFrame(() => setBox(selectionBox(active.start, point)));
    } else if (active.mode === 'lasso' && active.path) {
      appendPoint(
        active.path,
        point,
        (size.width / event.currentTarget.getBoundingClientRect().width) * 3,
      );
      frame.current = requestAnimationFrame(() => setLasso([...(active.path ?? []), point]));
    } else {
      if (!active.moved) select(active.glyphs);
      draftRef.current = movement(
        active.glyphs,
        point.x - active.start.x,
        point.y - active.start.y,
        snap && !event.altKey,
      );
      frame.current = requestAnimationFrame(() => setDraft(draftRef.current));
    }
    active.moved = true;
  }

  function cancel() {
    cancelAnimationFrame(frame.current);
    gesture.current = null;
    cornerDrag.current = null;
    setCornerDraft(undefined);
    draftRef.current = [];
    setDraft([]);
    setBox(undefined);
    setLasso([]);
  }

  function onPointerUp(event: PointerEvent<SVGSVGElement>) {
    const drag = cornerDrag.current;
    if (drag?.pointer === event.pointerId) {
      const point = local(event);
      const result =
        cornerChange(drag.frame, drag.index, point.x - drag.start.x, point.y - drag.start.y) ??
        drag.latest;
      if (result) applyCorner(drag.frame, result);
      cancel();
      return;
    }
    const active = gesture.current;
    if (!active || active.id !== event.pointerId) return;
    const point = local(event);
    if (!active.moved) {
      if (event.pointerType !== 'touch' || active.mode !== 'move')
        select(active.hit ? [active.hit] : [], active.append);
    } else if (active.mode === 'box' || active.mode === 'lasso') {
      const polygon = active.mode === 'lasso' ? [...(active.path ?? []), point] : undefined;
      const area = selectionBox(active.start, point);
      select(
        glyphs.filter((glyph) => {
          const bounds = pose(glyph, edits.get(glyph[0]));
          const center = { x: bounds.centerX, y: bounds.centerY };
          return polygon ? containsPoint(polygon, center) : inside(center, area);
        }),
        active.append,
      );
    } else if (active.mode === 'move')
      commit(
        movement(
          active.glyphs,
          point.x - active.start.x,
          point.y - active.start.y,
          snap && !event.altKey,
        ),
      );
    cancel();
  }

  function onKeyDown(event: KeyboardEvent<SVGSVGElement>) {
    if ((event.ctrlKey || event.metaKey) && ['z', 'y'].includes(event.key.toLowerCase())) {
      event.preventDefault();
      if (cornerDrag.current) cancel();
      history(event.shiftKey || event.key.toLowerCase() === 'y' ? 'redo' : 'undo');
    } else if (event.key === 'Escape') {
      const wasDragging = cornerDrag.current !== null;
      cancel();
      if (touchTool === 'perspective') {
        if (!wasDragging) setTouchTool('pan');
      } else select([]);
    } else if (selected.length) {
      const directions: Record<string, Point> = {
        ArrowLeft: { x: -1, y: 0 },
        ArrowRight: { x: 1, y: 0 },
        ArrowUp: { x: 0, y: -1 },
        ArrowDown: { x: 0, y: 1 },
      };
      const direction = directions[event.key];
      if (!direction) return;
      event.preventDefault();
      const amount = event.shiftKey ? 10 : 1;
      if (touchTool === 'perspective') {
        const target =
          event.target instanceof SVGElement ? event.target.dataset['corner'] : undefined;
        if (!perspective || target === undefined) return;
        const result = cornerChange(
          perspective,
          Number(target),
          direction.x * amount,
          direction.y * amount,
        );
        if (result) applyCorner(perspective, result);
        return;
      }
      commit(movement(selected, direction.x * amount, direction.y * amount, false));
    }
  }

  function transform(angle: number, horizontal: number, vertical: number) {
    const region = boundsOf(selected);
    if (!region || !(angle || horizontal || vertical)) return [];
    const cx = (region.left + region.right) / 2;
    const cy = (region.top + region.bottom) / 2;
    const gx = (2 * horizontal) / (100 * Math.max(1, region.right - region.left));
    const gy = (2 * vertical) / (100 * Math.max(1, region.bottom - region.top));
    return project(selected, (edit, p) =>
      transformWarp(edit.warp, { x: p.cx - cx, y: p.cy - cy }, angle, gx, gy),
    );
  }

  function project(
    items: Glyph[],
    map: (edit: Adjustment, geometry: ReturnType<typeof pose>) => Warp,
  ) {
    const result: Adjustment[] = [];
    for (const glyph of items) {
      const edit = position(glyph);
      const geometry = pose(glyph, edit);
      const { scale, cos, sin } = geometry;
      const warp = map(edit, geometry);
      if (!warpFits(warp, affineCorners(glyph[3], glyph[4], scale, cos, sin))) return;
      result.push({ ...edit, warp });
    }
    return result;
  }

  return {
    selected,
    quad,
    lasso,
    transform,
    displayed,
    box,
    snap,
    setSnap,
    touchTool,
    setTouchTool: (tool: typeof touchTool) => {
      cancel();
      setTouchTool(tool);
    },
    position,
    select,
    nudge: (dx: number, dy: number) => commit(movement(selected, dx, dy, false)),
    handlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel: cancel,
      onLostPointerCapture: cancel,
      onKeyDown,
    },
  };
}
