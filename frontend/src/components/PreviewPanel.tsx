import { useCallback, useRef, useState } from 'react';
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { useShallow } from 'zustand/react/shallow';
import { usePreviewStore } from '@/features/preview/store';
import { useInkMask } from '@/features/preview/useInkMask';
import { compositePreview } from '@/features/preview/compositePreview';
import FineEditCanvas from '@/features/preview/FineEditCanvas';
import { useFineEditStore } from '@/features/preview/fineEditStore';
import { useDocumentStore } from '@/features/document/store';
import type { FinePage } from '@/features/preview/fineEditModel';
import { sameFineLayout } from '@/features/preview/fineEditModel';
import { downloadResult } from '@/api/download';
import { useSettingsStore } from '@/features/settings/store';
import { useGenerationState } from '@/features/generation/state';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import GenerateButton, { useGenerationAvailability } from './GenerateButton';
import { useI18n } from '../i18n';
import { Card, CardHeader } from '../shared/ui/Card';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';
import PaperAreaControl from './PaperAreaControl';
import WorkspaceStatus from './WorkspaceStatus';
import {
  Eye,
  PenLine,
  ChevronLeft,
  ChevronRight,
  ZoomIn,
  ZoomOut,
  Maximize2,
  RotateCcw,
  LoaderCircle,
  Download,
  FileDown,
  Copy,
  ScanLine,
} from '../shared/icons';

type FineSheet = { page: FinePage; key: string; text: string | null };
export default function PreviewPanel({
  keepVisible = false,
  headingActions,
}: {
  keepVisible?: boolean;
  headingActions?: ReactNode;
}) {
  const { images, inkLayers, latinInkLayers, currentPage, setPage, fineEdit, revision } =
    usePreviewStore(
      useShallow((state) => ({
        images: state.images,
        inkLayers: state.inkLayers,
        latinInkLayers: state.latinInkLayers,
        currentPage: state.currentPage,
        setPage: state.setPage,
        fineEdit: state.fineEdit,
        revision: state.revision,
      })),
    );
  const { width, height, background, backgroundUrl, fullPreview, patch } = useSettingsStore(
    useShallow((state) => ({
      width: state.numbers.width,
      height: state.numbers.height,
      background: state.background,
      backgroundUrl: state.backgroundUrl,
      fullPreview: state.fullPreview,
      patch: state.patch,
    })),
  );
  const { generate } = useWorkspaceActions();
  const { disabled } = useGenerationAvailability();
  const { t } = useI18n();
  const [zoom, setZoom] = useState(100);
  const [expanded, setExpanded] = useState(false);
  const [editing, setEditing] = useState(false);
  const [inspector, setInspector] = useState<HTMLDivElement | null>(null);
  const draft = useDocumentStore();
  const { text } = draft;
  const finePage = fineEdit?.pages[currentPage];
  const fine =
    fineEdit && finePage ? { page: finePage, key: fineEdit.key, text: fineEdit.text } : undefined;
  const current = fine?.text === text;
  const settings = useSettingsStore();
  const source = usePreviewStore((state) => state.source);
  const needsRefresh = Boolean(
    fine &&
    (!current ||
      (source &&
        (source.draft.imageStore !== draft.imageStore ||
          !sameFineLayout(source.settings, settings)))),
  );
  const kickPreview = () => void generate('preview');
  const image = images[currentPage] ?? backgroundUrl;
  const ink = inkLayers[currentPage];
  const latinInk = latinInkLayers[currentPage] ?? undefined;
  const sizeLabel = (
    <span className="preview-size" title={background?.name}>
      {background ? background.name : `${width} × ${height}`}
    </span>
  );
  return (
    <Card className="preview-panel" id="workspace-panel-preview" data-testid="preview-panel">
      <CardHeader title={t('preview')} icon={<Eye size={18} />}>
        <div className="preview-heading-actions">
          {sizeLabel}
          {headingActions}
          <Button
            size="small"
            variant={editing ? 'tonal' : 'ghost'}
            aria-pressed={editing}
            data-testid="fine-edit-toggle"
            aria-label={t('fineEdit')}
            title={t('fineEdit')}
            className="fine-edit-toggle"
            disabled={!text.trim() || (disabled && !editing)}
            onClick={() => {
              setEditing(!editing);
              if (!editing && (!current || needsRefresh)) {
                useFineEditStore.getState().enable();
                kickPreview();
              }
            }}
          >
            <ScanLine size={15} />
            <span>{t('fineEdit')}</span>
          </Button>
        </div>
      </CardHeader>
      {headingActions && (
        <div className="canvas-status">
          <WorkspaceStatus />
        </div>
      )}
      <div className={`preview-canvas ${image ? '' : 'is-empty'}`} data-testid="preview-viewport">
        {!image ? (
          <div className="empty-preview">
            <div className="empty-paper">
              <PenLine size={30} />
              <span />
              <span />
              <span />
            </div>
            <h3>{t('emptyPreview')}</h3>
            <p>{t('emptyPreviewHint')}</p>
            {!headingActions && <GenerateButton compact />}
          </div>
        ) : (
          <PreviewSheet
            key={fine ? `${currentPage}:${revision}` : (ink ?? image)}
            image={image}
            ink={ink}
            latinInk={latinInk}
            zoom={zoom}
            fitPage={keepVisible}
            fine={fine}
            editing={editing && current && !needsRefresh}
            inspector={expanded ? null : inspector}
          />
        )}
        {!(keepVisible && image) && <PreviewProgress />}
      </div>
      <div className="fine-inspector-slot" ref={setInspector}>
        {((editing && !current) || needsRefresh) && (
          <p className="fine-inspector-note" role="status">
            {t('fineRefresh')}
            <Button size="small" variant="ghost" disabled={disabled} onClick={kickPreview}>
              {t('previewAction')}
            </Button>
          </p>
        )}
      </div>
      <footer className="preview-tools">
        <PreviewPages page={currentPage} count={images.length} setPage={setPage} />
        <div className="zoom-tools">
          <PreviewZoom zoom={zoom} setZoom={setZoom} disabled={!image} />
          <Button
            size="icon"
            variant="ghost"
            data-testid="expand-preview"
            aria-label={t('expandPreview')}
            title={t('expandPreview')}
            disabled={!image}
            onClick={() => setExpanded(true)}
          >
            <Maximize2 size={15} />
          </Button>
        </div>
      </footer>
      {background && (
        <div className="preview-paper-action">
          <PaperAreaControl inPreview />
        </div>
      )}
      <div className="export-bar">
        <label className="check-row">
          <input
            checked={fullPreview}
            onChange={(event) => patch({ fullPreview: event.currentTarget.checked })}
            type="checkbox"
            data-testid="full-preview-checkbox"
            aria-describedby={fullPreview && images.length > 3 ? 'long-preview-hint' : undefined}
          />
          <span>{t('fullPreview')}</span>
        </label>
        <div>
          <Button
            data-testid="generate-image-btn"
            variant="tonal"
            disabled={disabled || needsRefresh}
            onClick={() => void generate('zip')}
          >
            <Download size={16} />
            ZIP
          </Button>
          <Button
            variant="primary"
            data-testid="generate-pdf-btn"
            disabled={disabled || needsRefresh}
            onClick={() => void generate('pdf')}
          >
            <FileDown size={16} />
            PDF
          </Button>
        </div>
      </div>
      {fullPreview && images.length > 3 && (
        <p className="preview-scope-hint" id="long-preview-hint" role="status">
          {t('longPreviewHint')}
        </p>
      )}
      <AnimatePresence>
        {expanded && image && (
          <ExpandedPreview
            image={image}
            ink={ink}
            latinInk={latinInk}
            fine={fine}
            revision={revision}
            page={currentPage}
            count={images.length}
            setPage={setPage}
            close={() => setExpanded(false)}
          />
        )}
      </AnimatePresence>
    </Card>
  );
}

function PreviewPages({
  page,
  count,
  setPage,
  prefix = 'preview',
}: {
  page: number;
  count: number;
  setPage: (page: number) => void;
  prefix?: string;
}) {
  const { t } = useI18n();
  return (
    <div className="page-nav">
      <Button
        size="icon"
        variant="ghost"
        data-testid={`${prefix}-prev-btn`}
        aria-label={t('previous')}
        disabled={page === 0}
        onClick={() => setPage(page - 1)}
      >
        <ChevronLeft size={16} />
      </Button>
      <span data-testid={`${prefix}-page-indicator`}>
        {count ? page + 1 : 0} / {count}
      </span>
      <Button
        size="icon"
        variant="ghost"
        data-testid={`${prefix}-next-btn`}
        aria-label={t('next')}
        disabled={page >= count - 1}
        onClick={() => setPage(page + 1)}
      >
        <ChevronRight size={16} />
      </Button>
    </div>
  );
}

function PreviewZoom({
  zoom,
  setZoom,
  disabled = false,
}: {
  zoom: number;
  setZoom: (zoom: number) => void;
  disabled?: boolean;
}) {
  const { t } = useI18n();
  return (
    <>
      <Button
        size="icon"
        variant="ghost"
        aria-label={t('zoomOut')}
        disabled={disabled || zoom <= 25}
        onClick={() => setZoom(zoom - 25)}
      >
        <ZoomOut size={16} />
      </Button>
      <span>{zoom}%</span>
      <Button
        size="icon"
        variant="ghost"
        aria-label={t('zoomIn')}
        disabled={disabled || zoom >= 300}
        onClick={() => setZoom(zoom + 25)}
      >
        <ZoomIn size={16} />
      </Button>
      <Button
        size="icon"
        variant="ghost"
        aria-label={t('fit')}
        title={t('fit')}
        disabled={disabled || zoom === 100}
        onClick={() => setZoom(100)}
      >
        <RotateCcw size={15} />
      </Button>
    </>
  );
}

function ExpandedPreview({
  image,
  ink,
  latinInk,
  fine,
  revision,
  page,
  count,
  setPage,
  close,
}: {
  image: string;
  ink: string | undefined;
  latinInk: string | undefined;
  fine: FineSheet | undefined;
  revision: number;
  page: number;
  count: number;
  setPage: (page: number) => void;
  close: () => void;
}) {
  const { t } = useI18n();
  const [zoom, setZoom] = useState(100);
  return (
    <Modal
      title={t('expandPreview')}
      closeLabel={t('close')}
      onClose={close}
      testId="fullscreen-preview"
      className="preview-modal"
    >
      <div className="preview-canvas" data-testid="expanded-preview-viewport">
        <PreviewSheet
          key={fine ? `${page}:${revision}` : (ink ?? image)}
          image={image}
          ink={ink}
          latinInk={latinInk}
          zoom={zoom}
          expanded
          fine={fine}
        />
      </div>
      <footer className="preview-tools">
        {count > 1 && (
          <PreviewPages page={page} count={count} setPage={setPage} prefix="expanded-preview" />
        )}
        <div className="zoom-tools">
          <PreviewZoom zoom={zoom} setZoom={setZoom} />
        </div>
      </footer>
    </Modal>
  );
}

function PreviewSheet({
  image,
  ink,
  latinInk,
  zoom,
  expanded = false,
  fitPage = false,
  fine,
  editing = false,
  inspector = null,
}: {
  image: string;
  ink: string | undefined;
  latinInk: string | undefined;
  zoom: number;
  expanded?: boolean;
  fitPage?: boolean;
  fine?: FineSheet | undefined;
  editing?: boolean;
  inspector?: HTMLElement | null;
}) {
  const { t } = useI18n();
  const [loaded, setLoaded] = useState(false);
  const [aspect, setAspect] = useState(1);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [fineReady, setFineReady] = useState(false);
  const fineHandle = useRef<{ png: () => Promise<Blob> }>(null);
  const registerFineHandle = useCallback((handle: { png: () => Promise<Blob> } | null) => {
    fineHandle.current = handle;
    setFineReady(Boolean(handle));
  }, []);
  const [imageActionStatus, setImageActionStatus] = useState('');
  const paper = useRef<HTMLImageElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const color = useSettingsStore((state) => state.ink);
  const opacity = useSettingsStore((state) => state.numbers.ink_opacity) / 100;
  const thickness = useSettingsStore((state) => state.numbers.ink_thickness);
  const softness = useSettingsStore((state) => state.numbers.ink_softness);
  const latinColor = useSettingsStore((state) =>
    state.separateLatinInk ? state.latinInk : state.ink,
  );
  const latinOpacity =
    useSettingsStore((state) =>
      state.separateLatinInk ? state.numbers.latin_ink_opacity : state.numbers.ink_opacity,
    ) / 100;
  const latinShape = useSettingsStore(
    useShallow((state) => ({
      thickness: state.separateLatinInk
        ? state.numbers.latin_ink_thickness
        : state.numbers.ink_thickness,
      softness: state.separateLatinInk
        ? state.numbers.latin_ink_softness
        : state.numbers.ink_softness,
    })),
  );
  const mask = useInkMask(ink, { thickness, softness });
  const latinMask = useInkMask(latinInk, latinShape);
  const reduced = useReducedMotion();
  const prefix = expanded ? 'expanded-preview' : 'preview';
  const width =
    expanded || fitPage ? `calc(min(100cqw, ${aspect * 100}cqh) * ${zoom / 100})` : `${zoom}%`;
  const canCopy = Boolean(mask) || fineReady;

  function openImageMenu(x: number, y: number) {
    const element = menu.current;
    if (!element) return;
    setImageActionStatus('');
    element.showPopover();
    element.style.left = `${Math.max(8, Math.min(x, window.innerWidth - element.offsetWidth - 8))}px`;
    element.style.top = `${Math.max(8, Math.min(y, window.innerHeight - element.offsetHeight - 8))}px`;
    element.querySelector('button')?.focus();
  }

  async function handleImageAction(action: 'copy' | 'save') {
    const background = paper.current;
    if (!background || (!mask && !fineHandle.current)) return;
    const inks = mask ? [{ mask, color, opacity }] : [];
    if (latinMask) inks.push({ mask: latinMask, color: latinColor, opacity: latinOpacity });
    const png = () => fineHandle.current?.png() ?? compositePreview(background, inks);
    try {
      if (action === 'copy') {
        if (!navigator.clipboard || typeof ClipboardItem !== 'function') {
          throw new Error('Image clipboard unavailable');
        }
        // Start the write within the click; the PNG can finish encoding asynchronously.
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': png() })]);
        setImageActionStatus(t('previewImageCopied'));
      } else {
        downloadResult(await png(), 'png');
        menu.current?.hidePopover();
      }
    } catch {
      setImageActionStatus(
        t(action === 'copy' ? 'previewImageCopyFailed' : 'previewImageSaveFailed'),
      );
    }
  }

  function onContextMenu(event: MouseEvent<HTMLElement | SVGElement>) {
    if (!canCopy) return;
    event.preventDefault();
    openImageMenu(event.clientX, event.clientY);
  }

  function onMenuKey(event: KeyboardEvent<HTMLElement | SVGElement>) {
    if (!canCopy || (event.key !== 'ContextMenu' && !(event.shiftKey && event.key === 'F10')))
      return;
    event.preventDefault();
    const bounds = event.currentTarget.getBoundingClientRect();
    openImageMenu(bounds.left, bounds.top);
  }

  return (
    <motion.div
      className="preview-sheet"
      style={{ width }}
      initial={{ opacity: 0 }}
      animate={{ opacity: loaded ? 1 : 0 }}
      transition={{ duration: reduced ? 0 : 0.2 }}
    >
      <img
        ref={paper}
        src={image}
        data-testid={`${prefix}-image`}
        className="preview-image"
        onLoad={(event) => {
          const { naturalWidth, naturalHeight } = event.currentTarget;
          if ((expanded || fitPage) && naturalHeight) setAspect(naturalWidth / naturalHeight);
          setSize({ width: naturalWidth, height: naturalHeight });
          setLoaded(true);
        }}
        tabIndex={canCopy && !editing ? 0 : undefined}
        onContextMenu={onContextMenu}
        onKeyDown={onMenuKey}
        alt={t('preview')}
      />
      {fine && (
        <FineEditCanvas
          page={fine.page}
          paper={paper}
          size={size}
          modelKey={fine.key}
          text={fine.text}
          editing={editing}
          inspector={inspector}
          handle={registerFineHandle}
          onContextMenu={onContextMenu}
          onMenuKey={onMenuKey}
          prefix={prefix}
        />
      )}
      {mask && (
        <>
          <div
            className="preview-ink-layer"
            aria-hidden="true"
            data-testid={`${prefix}-ink-layer`}
            style={{ backgroundColor: color, opacity, maskImage: `url("${mask}")` }}
          />
          {latinMask && (
            <div
              className="preview-ink-layer"
              aria-hidden="true"
              data-testid={`${prefix}-latin-ink-layer`}
              style={{
                backgroundColor: latinColor,
                opacity: latinOpacity,
                maskImage: `url("${latinMask}")`,
              }}
            />
          )}
        </>
      )}
      {canCopy && (
        <div ref={menu} className="preview-image-menu" popover="auto">
          <Button
            variant="ghost"
            size="small"
            data-testid={`${prefix}-copy-image`}
            onClick={() => void handleImageAction('copy')}
          >
            <Copy size={16} />
            {t('copyPreviewImage')}
          </Button>
          <Button
            variant="ghost"
            size="small"
            data-testid={`${prefix}-save-image`}
            onClick={() => void handleImageAction('save')}
          >
            <Download size={16} />
            {t('savePreviewImage')}
          </Button>
          <span role="status" hidden={!imageActionStatus}>
            {imageActionStatus}
          </span>
        </div>
      )}
    </motion.div>
  );
}

function PreviewProgress() {
  const { t } = useI18n();
  const reduced = useReducedMotion();
  const busy = useGenerationState((state) => state.busy);
  const progress = useGenerationState((state) => state.progress);
  return (
    <AnimatePresence>
      {busy && (
        <motion.div
          key="progress"
          className="preview-progress"
          role="status"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: reduced ? 0 : 0.2 }}
        >
          <LoaderCircle className="spin" size={22} />
          <p>{t('working')}</p>
          <progress value={progress} max="100" />
        </motion.div>
      )}
    </AnimatePresence>
  );
}
