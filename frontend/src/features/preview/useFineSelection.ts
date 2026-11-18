import { useEffect, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent, PointerEvent } from 'react';
import { defaultAdjustment } from './fineEditModel';
import type { Adjustment, Adjustments, Glyph } from './fineEditModel';
import { overlaps, pose, union } from './fineRaster';
import type { Bounds } from './fineRaster';

type Point = { x: number; y: number };
type Gesture = {
  id: number;
  start: Point;
  screen: Point;
  moved: boolean;
  mode: 'move' | 'box' | 'tap';
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
  const [draft, setDraft] = useState<Adjustment[]>([]);
  const [snap, setSnap] = useState(true);
  const [touchTool, setTouchTool] = useState<'pan' | 'box' | 'move'>('pan');
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
    if (event.button !== 0 || gesture.current) return;
    if (event.pointerType === 'touch' && !event.isPrimary) return;
    const start = local(event);
    let unit: Glyph | undefined;
    for (let i = glyphs.length - 1; i >= 0; i -= 1) {
      const glyph = glyphs[i];
      if (
        glyph &&
        inside(start, pose(glyph, edits.get(glyph[0])), event.pointerType === 'touch' ? 3 : 0)
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
      mode:
        event.pointerType === 'touch'
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

  function onPointerMove(event: PointerEvent<SVGSVGElement>) {
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
    draftRef.current = [];
    setDraft([]);
    setBox(undefined);
  }

  function onPointerUp(event: PointerEvent<SVGSVGElement>) {
    const active = gesture.current;
    if (!active || active.id !== event.pointerId) return;
    const point = local(event);
    if (!active.moved) {
      if (event.pointerType !== 'touch' || active.mode !== 'move')
        select(active.hit ? [active.hit] : [], active.append);
    } else if (active.mode === 'box') {
      const area = selectionBox(active.start, point);
      select(
        glyphs.filter((glyph) => {
          const bounds = pose(glyph, edits.get(glyph[0]));
          return overlaps(area, bounds) && inside({ x: bounds.cx, y: bounds.cy }, area);
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
      history(event.shiftKey || event.key.toLowerCase() === 'y' ? 'redo' : 'undo');
    } else if (event.key === 'Escape') {
      cancel();
      select([]);
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
      commit(movement(selected, direction.x * amount, direction.y * amount, false));
    }
  }

  return {
    selected,
    displayed,
    box,
    snap,
    setSnap,
    touchTool,
    setTouchTool,
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
