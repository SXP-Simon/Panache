import { useRef, useState } from 'react';
import type { PointerEvent } from 'react';
import { useI18n } from '@/i18n';
import { useSettingsStore } from '@/features/settings/store';
import { useNotificationStore } from '@/features/notifications/store';
import { clearPreview } from '@/features/preview/resources';
import { paperAreaLayout } from '@/features/workspace/paperArea';
import type { PaperArea, PaperSize } from '@/features/workspace/paperArea';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';

type Point = { x: number; y: number };
const corners = ['nw', 'ne', 'sw', 'se'] as const;
type Corner = (typeof corners)[number];
const limit = (value: number, max: number) => Math.max(0, Math.min(value, max));

export default function PaperAreaDialog({ source, close }: { source: string; close: () => void }) {
  const { t } = useI18n();
  const [size, setSize] = useState<PaperSize | null>(null);
  const [area, setArea] = useState<PaperArea | null>(null);
  const [rowInput, setRowInput] = useState<string | null>(null);
  const [spacing, setSpacing] = useState(1);
  const [loadError, setLoadError] = useState(false);
  const drag = useRef<{
    id: number;
    anchor: Point;
    start: Point;
    original: PaperArea | null;
  } | null>(null);
  const rows =
    rowInput ??
    (area ? String(Math.max(2, Math.round((area.last - area.first) / spacing) + 1)) : '');
  const layout = area && size ? paperAreaLayout(area, size, Number(rows)) : null;

  function initialize(image: HTMLImageElement) {
    const paper = { width: image.naturalWidth, height: image.naturalHeight };
    const numbers = useSettingsStore.getState().numbers;
    const step = Math.min(Math.floor(paper.height * 0.16), Math.max(8, numbers.line_spacing));
    setSpacing(Math.max(1, step));
    setSize(paper);
    setArea({
      left: Math.min(numbers.left_margin, paper.width * 0.3),
      right: Math.max(paper.width - numbers.right_margin, paper.width * 0.7),
      first: Math.min(numbers.top_margin + step, paper.height * 0.55),
      last: Math.min(
        paper.height - 1,
        Math.max(paper.height * 0.65, paper.height - numbers.bottom_margin - Math.ceil(step / 4)),
      ),
    });
  }

  function point(event: PointerEvent<HTMLDivElement>): Point {
    const box = event.currentTarget.getBoundingClientRect();
    return {
      x: limit(((event.clientX - box.left) / box.width) * (size?.width ?? 0), size?.width ?? 0),
      y: limit(
        ((event.clientY - box.top) / box.height) * (size?.height ?? 0),
        (size?.height ?? 1) - 1,
      ),
    };
  }

  function startDrag(event: PointerEvent<HTMLDivElement>) {
    if (!size || !area || event.button !== 0 || drag.current) return;
    event.preventDefault();
    const start = point(event);
    const corner =
      event.target instanceof HTMLElement
        ? (event.target.dataset['corner'] as Corner | undefined)
        : undefined;
    const anchor = corner
      ? {
          x: corner.endsWith('w') ? area.right : area.left,
          y: corner.startsWith('n') ? area.last : area.first,
        }
      : start;
    drag.current = { id: event.pointerId, anchor, start, original: area };
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function moveDrag(event: PointerEvent<HTMLDivElement>) {
    const current = drag.current;
    if (!current || current.id !== event.pointerId) return;
    const next = point(event);
    if (Math.abs(next.x - current.start.x) + Math.abs(next.y - current.start.y) < 3) return;
    setArea({
      left: Math.min(next.x, current.anchor.x),
      right: Math.max(next.x, current.anchor.x),
      first: Math.min(next.y, current.anchor.y),
      last: Math.max(next.y, current.anchor.y),
    });
  }

  function applyArea() {
    const settings = useSettingsStore.getState();
    if (!layout || settings.backgroundUrl !== source) return;
    settings.patch({
      numbers: {
        ...settings.numbers,
        ...layout,
        font_size:
          settings.numbers.font_size > layout.line_spacing
            ? Math.max(1, Math.floor(layout.line_spacing * 0.72))
            : settings.numbers.font_size,
      },
      backgroundRuled: true,
    });
    clearPreview();
    useNotificationStore.getState().inform('paperAreaApplied');
    close();
  }

  return (
    <Modal
      title={t('paperAreaTitle')}
      closeLabel={t('close')}
      onClose={close}
      testId="paper-area-dialog"
      className="paper-area-modal"
    >
      <p className="help-text">{t('paperAreaHelp')}</p>
      <div className="paper-area-scroller">
        <div
          className="paper-area-image"
          data-testid="paper-area-image"
          onPointerDown={startDrag}
          onPointerMove={moveDrag}
          onPointerUp={() => {
            drag.current = null;
          }}
          onPointerCancel={() => {
            if (drag.current) setArea(drag.current.original);
            drag.current = null;
          }}
        >
          <img
            src={source}
            alt={t('background')}
            draggable={false}
            onLoad={(event) => initialize(event.currentTarget)}
            onError={() => setLoadError(true)}
          />
          {area && size && (
            <div
              className="paper-area-selection"
              data-testid="paper-area-selection"
              style={{
                left: `${(100 * area.left) / size.width}%`,
                top: `${(100 * area.first) / size.height}%`,
                width: `${(100 * (area.right - area.left)) / size.width}%`,
                height: `${(100 * (area.last - area.first)) / size.height}%`,
              }}
            >
              {layout &&
                Array.from({ length: Number(rows) - 2 }, (_, index) => (
                  <span
                    className="paper-area-guide"
                    key={index}
                    style={{ top: `${(100 * (index + 1)) / (Number(rows) - 1)}%` }}
                  />
                ))}
              {corners.map((corner) => (
                <span className={`paper-area-handle ${corner}`} key={corner} data-corner={corner} />
              ))}
            </div>
          )}
        </div>
      </div>
      <footer className="paper-area-footer">
        <label className="field-label">
          {t('paperAreaRows')}
          <input
            data-testid="paper-area-rows"
            type="number"
            min="2"
            max="500"
            value={rows}
            onChange={(event) => setRowInput(event.currentTarget.value)}
          />
        </label>
        <p className="help-text" aria-live="polite">
          {loadError
            ? t('invalidResponse')
            : layout
              ? `${t('lineSpacing')} ${layout.line_spacing} px`
              : t('paperAreaInvalid')}
        </p>
        <div className="modal-actions">
          <Button onClick={close}>{t('cancel')}</Button>
          <Button
            variant="primary"
            data-testid="paper-area-apply"
            disabled={!layout}
            onClick={applyArea}
          >
            {t('paperAreaApply')}
          </Button>
        </div>
      </footer>
    </Modal>
  );
}
