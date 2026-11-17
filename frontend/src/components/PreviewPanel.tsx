import { useRef, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { useShallow } from 'zustand/react/shallow';
import { usePreviewStore } from '@/features/preview/store';
import { useInkMask } from '@/features/preview/useInkMask';
import { compositePreview } from '@/features/preview/compositePreview';
import { downloadResult } from '@/api/download';
import { useSettingsStore } from '@/features/settings/store';
import { useGenerationState } from '@/features/generation/state';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import GenerateButton, { useGenerationAvailability } from './GenerateButton';
import { useI18n } from '../i18n';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';
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
} from '../shared/icons';
export default function PreviewPanel() {
  const { images, inkLayers, currentPage, setPage } = usePreviewStore(
    useShallow((state) => ({
      images: state.images,
      inkLayers: state.inkLayers,
      currentPage: state.currentPage,
      setPage: state.setPage,
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
  const image = images[currentPage] ?? backgroundUrl;
  const ink = inkLayers[currentPage];
  return (
    <section className="panel preview-panel" data-testid="preview-panel">
      <header className="panel-heading">
        <div>
          <p className="eyebrow">03 / {t('previewHint')}</p>
          <h2>
            <Eye size={18} />
            {t('preview')}
          </h2>
        </div>
        <span className="preview-size">
          {background ? background.name : `${width} × ${height}`}
        </span>
      </header>
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
            <GenerateButton compact />
          </div>
        ) : (
          <PreviewSheet key={ink ?? image} image={image} ink={ink} zoom={zoom} />
        )}
        <PreviewProgress />
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
      <div className="export-bar">
        <label className="check-row">
          <input
            checked={fullPreview}
            onChange={(event) => patch({ fullPreview: event.currentTarget.checked })}
            type="checkbox"
            data-testid="full-preview-checkbox"
          />
          <span>{t('fullPreview')}</span>
        </label>
        <div>
          <Button
            data-testid="generate-image-btn"
            disabled={disabled}
            onClick={() => void generate('zip')}
          >
            <Download size={16} />
            ZIP
          </Button>
          <Button
            variant="primary"
            data-testid="generate-pdf-btn"
            disabled={disabled}
            onClick={() => void generate('pdf')}
          >
            <FileDown size={16} />
            PDF
          </Button>
        </div>
      </div>
      <AnimatePresence>
        {expanded && image && (
          <ExpandedPreview
            image={image}
            ink={ink}
            page={currentPage}
            count={images.length}
            setPage={setPage}
            close={() => setExpanded(false)}
          />
        )}
      </AnimatePresence>
    </section>
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
  page,
  count,
  setPage,
  close,
}: {
  image: string;
  ink: string | undefined;
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
        <PreviewSheet key={ink ?? image} image={image} ink={ink} zoom={zoom} expanded />
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
  zoom,
  expanded = false,
}: {
  image: string;
  ink: string | undefined;
  zoom: number;
  expanded?: boolean;
}) {
  const { t } = useI18n();
  const [loaded, setLoaded] = useState(false);
  const [aspect, setAspect] = useState(1);
  const [imageActionStatus, setImageActionStatus] = useState('');
  const paper = useRef<HTMLImageElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const color = useSettingsStore((state) => state.ink);
  const opacity = useSettingsStore((state) => state.numbers.ink_opacity) / 100;
  const thickness = useSettingsStore((state) => state.numbers.ink_thickness);
  const softness = useSettingsStore((state) => state.numbers.ink_softness);
  const mask = useInkMask(ink, { thickness, softness });
  const reduced = useReducedMotion();
  const prefix = expanded ? 'expanded-preview' : 'preview';
  const width = expanded ? `calc(min(100cqw, ${aspect * 100}cqh) * ${zoom / 100})` : `${zoom}%`;

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
    if (!background || !mask) return;
    try {
      if (action === 'copy') {
        if (!navigator.clipboard || typeof ClipboardItem !== 'function') {
          throw new Error('Image clipboard unavailable');
        }
        // Start the write within the click; the PNG can finish encoding asynchronously.
        const png = compositePreview(background, mask, color, opacity);
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': png })]);
        setImageActionStatus(t('previewImageCopied'));
      } else {
        downloadResult(await compositePreview(background, mask, color, opacity), 'png');
        menu.current?.hidePopover();
      }
    } catch {
      setImageActionStatus(
        t(action === 'copy' ? 'previewImageCopyFailed' : 'previewImageSaveFailed'),
      );
    }
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
          if (expanded && naturalHeight) setAspect(naturalWidth / naturalHeight);
          setLoaded(true);
        }}
        tabIndex={mask ? 0 : undefined}
        onContextMenu={(event) => {
          if (!mask) return;
          event.preventDefault();
          openImageMenu(event.clientX, event.clientY);
        }}
        onKeyDown={(event) => {
          if (!mask || (event.key !== 'ContextMenu' && !(event.shiftKey && event.key === 'F10')))
            return;
          event.preventDefault();
          const bounds = event.currentTarget.getBoundingClientRect();
          openImageMenu(bounds.left, bounds.top);
        }}
        alt={t('preview')}
      />
      {mask && (
        <>
          <div
            className="preview-ink-layer"
            aria-hidden="true"
            data-testid={`${prefix}-ink-layer`}
            style={{ backgroundColor: color, opacity, maskImage: `url("${mask}")` }}
          />
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
        </>
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
