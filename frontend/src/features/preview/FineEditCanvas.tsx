import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent, MouseEvent, RefObject } from 'react';
import { createPortal } from 'react-dom';
import { useShallow } from 'zustand/react/shallow';
import { useI18n } from '@/i18n';
import { useSettingsStore } from '@/features/settings/store';
import Button from '@/shared/ui/Button';
import { ChevronLeft, ChevronRight, RotateCcw } from '@/shared/icons';
import { defaultAdjustment } from './fineEditModel';
import type { Adjustment, Adjustments, FinePage } from './fineEditModel';
import { FineRaster, pose, union } from './fineRaster';
import type { FineInk } from './fineRaster';
import { useFineSelection } from './useFineSelection';
import { useFineEditStore } from './fineEditStore';

type Handle = { png: () => Promise<Blob> };

export default function FineEditCanvas({
  page,
  paper,
  modelKey,
  text,
  size,
  editing,
  inspector,
  handle,
  onContextMenu,
  onMenuKey,
  prefix,
}: {
  page: FinePage;
  paper: RefObject<HTMLImageElement | null>;
  modelKey: string;
  text: string | null;
  size: { width: number; height: number };
  editing: boolean;
  inspector: HTMLElement | null;
  handle: (handle: Handle | null) => void;
  onContextMenu: (event: MouseEvent<SVGSVGElement>) => void;
  onMenuKey: (event: KeyboardEvent<SVGSVGElement>) => void;
  prefix: string;
}) {
  const { t } = useI18n();
  const paperInk = useSettingsStore(
    useShallow((state) => ({
      color: state.ink,
      opacity: state.numbers.ink_opacity,
      thickness: state.numbers.ink_thickness,
      softness: state.numbers.ink_softness,
    })),
  );
  const latinInk = useSettingsStore(
    useShallow((state) =>
      state.separateLatinInk
        ? {
            color: state.latinInk,
            opacity: state.numbers.latin_ink_opacity,
            thickness: state.numbers.latin_ink_thickness,
            softness: state.numbers.latin_ink_softness,
          }
        : null,
    ),
  );
  const styles = useMemo<[FineInk, FineInk]>(
    () => [paperInk, latinInk ?? paperInk],
    [latinInk, paperInk],
  );
  const saved = useFineEditStore((state) => state.saved);
  const apply = useFineEditStore((state) => state.apply);
  const step = useFineEditStore((state) => state.step);
  const source = useFineEditStore((state) => state.sourceSelection);
  const selectSource = useFineEditStore((state) => state.selectSource);
  const undo = useFineEditStore((state) => state.undo.length > 0);
  const redo = useFineEditStore((state) => state.redo.length > 0);
  const canvas = useRef<HTMLCanvasElement>(null);
  const paint = useRef<FineRaster>(null);
  const latest = useRef<{ edits: Adjustments; styles: [FineInk, FineInk] }>(null);
  const [atlas, setAtlas] = useState<HTMLImageElement>();
  const [failed, setFailed] = useState(false);
  const [styleDraft, setStyleDraft] = useState<Adjustment[]>([]);
  const batch = useRef<Adjustment[]>([]);
  const edits = useMemoAdjustments(saved?.key === modelKey ? saved.glyphs : undefined);
  const sourceIds = useMemo(() => {
    if (!source || source.text !== text || !page.source_ranges?.some(Boolean)) return undefined;
    const ids = new Set<number>();
    page.glyphs.forEach(([id], index) => {
      const range = page.source_ranges?.[index];
      if (range && range[0] < source.end && range[1] > source.start) ids.add(id);
    });
    return ids;
  }, [page, source, text]);
  const selection = useFineSelection({
    glyphs: page.glyphs,
    edits,
    size,
    commit,
    history: step,
    sourceIds,
    clearSource: () => {
      if (source) selectSource(null);
    },
  });
  const overrides = useMemoAdjustments(
    styleDraft.length ? styleDraft : undefined,
    selection.displayed,
  );

  function commit(values: Adjustment[]) {
    if (text !== null && values.length) apply(text, modelKey, values);
  }

  useEffect(() => {
    let current = true;
    const image = new Image();
    image.src = `data:image/png;base64,${page.atlas}`;
    void image
      .decode()
      .then(() => {
        if (current) setAtlas(image);
      })
      .catch(() => {
        if (current) setFailed(true);
      });
    return () => {
      current = false;
    };
  }, [page.atlas]);

  useLayoutEffect(() => {
    if (!canvas.current || !paper.current || !atlas || !size.width) return;
    try {
      const renderer = new FineRaster(canvas.current, paper.current, atlas, page);
      paint.current = renderer;
      handle({
        png: () => {
          const model = latest.current;
          return model
            ? renderer.png(model.edits, model.styles)
            : Promise.reject(new Error('Preview not ready'));
        },
      });
    } catch {
      queueMicrotask(() => setFailed(true));
    }
    return () => {
      handle(null);
      paint.current = null;
    };
  }, [atlas, handle, page, paper, size.width]);

  useLayoutEffect(() => {
    latest.current = { edits: overrides, styles };
    paint.current?.draw(overrides, styles);
  }, [atlas, overrides, page, size.width, styles]);

  const active = editing && Boolean(atlas) && !failed && text !== null && size.width > 0;
  const marks = active
    ? selection.selected.map((glyph) => ({ id: glyph[0], ...pose(glyph, overrides.get(glyph[0])) }))
    : [];
  const group = marks.reduce<(typeof marks)[number] | ReturnType<typeof union> | undefined>(
    (acc, mark) => (acc ? union(acc, mark) : mark),
    undefined,
  );
  const first = selection.selected[0];
  const values = first ? (overrides.get(first[0]) ?? defaultAdjustment) : defaultAdjustment;

  function change(patch: Partial<Adjustment>) {
    batch.current = selection.selected.map((glyph) => ({ ...selection.position(glyph), ...patch }));
    setStyleDraft(batch.current);
  }

  function finish() {
    commit(batch.current);
    batch.current = [];
    setStyleDraft([]);
  }

  return (
    <>
      <canvas
        ref={canvas}
        className="fine-raster"
        data-testid={`${prefix}-fine-raster`}
        aria-hidden="true"
      />
      {active && (
        <svg
          className="fine-selection"
          data-touch-tool={selection.touchTool}
          role="group"
          aria-label={t('fineEdit')}
          tabIndex={0}
          data-testid="fine-selection"
          viewBox={`0 0 ${size.width} ${size.height}`}
          {...selection.handlers}
          onPointerDown={(event) => {
            if (batch.current.length) finish();
            selection.handlers.onPointerDown(event);
          }}
          onContextMenu={onContextMenu}
          onKeyDown={(event) => {
            onMenuKey(event);
            if (!event.defaultPrevented) selection.handlers.onKeyDown(event);
          }}
        >
          {marks.map((mark) => (
            <rect
              key={mark.id}
              data-testid="fine-selected-glyph"
              data-glyph={mark.id}
              x={mark.left}
              y={mark.top}
              width={mark.right - mark.left}
              height={mark.bottom - mark.top}
            />
          ))}
          {group && (
            <rect
              className="fine-selection-outline"
              x={group.left}
              y={group.top}
              width={group.right - group.left}
              height={group.bottom - group.top}
            />
          )}
          {selection.box && (
            <rect
              className="fine-marquee"
              x={selection.box.left}
              y={selection.box.top}
              width={selection.box.right - selection.box.left}
              height={selection.box.bottom - selection.box.top}
            />
          )}
        </svg>
      )}
      {editing &&
        inspector &&
        createPortal(
          <div className="fine-inspector" data-testid="fine-inspector">
            <div className="fine-inspector-head">
              <span aria-live="polite">
                {failed
                  ? t('fineUnavailable')
                  : first
                    ? t('fineSelected').replace('{count}', String(marks.length))
                    : t('fineHint')}
              </span>
              <div className="fine-history">
                <Button
                  size="icon"
                  variant="ghost"
                  aria-label={t('fineUndo')}
                  title={t('fineUndo')}
                  disabled={!undo}
                  onClick={() => step('undo')}
                  data-testid="fine-undo"
                >
                  <ChevronLeft size={16} />
                </Button>
                <Button
                  size="icon"
                  variant="ghost"
                  aria-label={t('fineRedo')}
                  title={t('fineRedo')}
                  disabled={!redo}
                  onClick={() => step('redo')}
                  data-testid="fine-redo"
                >
                  <ChevronRight size={16} />
                </Button>
              </div>
            </div>
            <div className="fine-touch-tools" aria-label={t('fineEdit')}>
              {(
                [
                  ['pan', 'fineTap'],
                  ['box', 'fineBox'],
                  ['move', 'fineMove'],
                ] as const
              ).map(([tool, label]) => (
                <Button
                  key={tool}
                  size="small"
                  variant={selection.touchTool === tool ? 'tonal' : 'ghost'}
                  aria-pressed={selection.touchTool === tool}
                  disabled={tool === 'move' && !first}
                  data-testid={`fine-touch-${tool}`}
                  onPointerUp={(event) => {
                    if (event.pointerType === 'touch') selection.setTouchTool(tool);
                  }}
                  onClick={() => selection.setTouchTool(tool)}
                >
                  {t(label)}
                </Button>
              ))}
            </div>
            {first && active && (
              <div className="fine-fields">
                {(
                  [
                    ['scale', 'fineScale', 50, 200, '%'],
                    ['angle', 'fineAngle', -45, 45, '°'],
                    ['opacity', 'fineOpacity', 0, 100, '%'],
                  ] as const
                ).map(([field, label, min, max, unit]) => (
                  <label key={field}>
                    <span>
                      {t(label)}{' '}
                      <output>
                        {values[field]}
                        {unit}
                      </output>
                    </span>
                    <input
                      type="range"
                      min={min}
                      max={max}
                      value={values[field]}
                      data-testid={`fine-${field}`}
                      onChange={(event) => change({ [field]: event.currentTarget.valueAsNumber })}
                      onPointerUp={finish}
                      onPointerCancel={finish}
                      onKeyUp={finish}
                      onBlur={finish}
                    />
                  </label>
                ))}
                <label className="fine-color">
                  {t('fineColor')}
                  <input
                    type="color"
                    value={values.color ?? paperInk.color}
                    data-testid="fine-color"
                    onChange={(event) => {
                      const color = event.currentTarget.value;
                      commit(
                        selection.selected.map((glyph) => ({
                          ...selection.position(glyph),
                          color,
                        })),
                      );
                    }}
                  />
                </label>
                <label className="check-row">
                  <input
                    type="checkbox"
                    data-testid="fine-snap"
                    checked={selection.snap}
                    onChange={(event) => selection.setSnap(event.currentTarget.checked)}
                  />
                  {t('fineSnap')}
                </label>
                <div className="fine-nudges" aria-label={t('fineNudge')}>
                  {(
                    [
                      [-1, 0, 'fineLeft', '←'],
                      [0, -1, 'fineUp', '↑'],
                      [0, 1, 'fineDown', '↓'],
                      [1, 0, 'fineRight', '→'],
                    ] as const
                  ).map(([dx, dy, label, arrow]) => (
                    <Button
                      key={label}
                      size="icon"
                      variant="ghost"
                      aria-label={t(label)}
                      onClick={() => selection.nudge(dx, dy)}
                    >
                      {arrow}
                    </Button>
                  ))}
                </div>
                <Button
                  size="small"
                  variant="ghost"
                  data-testid="fine-reset"
                  onClick={() =>
                    commit(selection.selected.map(([id]) => ({ id, ...defaultAdjustment })))
                  }
                >
                  <RotateCcw size={14} />
                  {t('fineReset')}
                </Button>
              </div>
            )}
          </div>,
          inspector,
        )}
    </>
  );
}

function useMemoAdjustments(values?: readonly Adjustment[], base?: Adjustments): Adjustments {
  return useMemo(() => {
    if (!values?.length && base) return base;
    const result = new Map(base);
    for (const value of values ?? []) result.set(value.id, value);
    return result;
  }, [base, values]);
}
