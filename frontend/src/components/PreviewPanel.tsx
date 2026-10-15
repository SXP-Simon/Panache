import { useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { useShallow } from 'zustand/react/shallow';
import { usePreviewStore } from '@/features/preview/store';
import { useSettingsStore } from '@/features/settings/store';
import { useGenerationState } from '@/features/generation/state';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import GenerateButton, { useGenerationAvailability } from './GenerateButton';
import { useI18n } from '../i18n';
import Button from '../shared/ui/Button';
import {
  Eye,
  PenLine,
  ChevronLeft,
  ChevronRight,
  ZoomIn,
  ZoomOut,
  Maximize2,
  LoaderCircle,
  Download,
  FileDown,
} from '../shared/icons';
export default function PreviewPanel() {
  const { images, currentPage, setPage } = usePreviewStore(
    useShallow((state) => ({
      images: state.images,
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
  const image = images[currentPage] ?? backgroundUrl;
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
      <div className={`preview-canvas ${image ? '' : 'is-empty'}`}>
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
          <PreviewImage key={image} src={image} zoom={zoom} alt={t('preview')} />
        )}{' '}
        <PreviewProgress />
      </div>
      <footer className="preview-tools">
        <div className="page-nav">
          <Button
            size="icon"
            variant="ghost"
            data-testid="preview-prev-btn"
            aria-label={t('previous')}
            disabled={currentPage === 0}
            onClick={() => setPage(currentPage - 1)}
          >
            <ChevronLeft size={16} />
          </Button>
          <span data-testid="preview-page-indicator">
            {images.length ? currentPage + 1 : 0} / {images.length}
          </span>
          <Button
            size="icon"
            variant="ghost"
            data-testid="preview-next-btn"
            aria-label={t('next')}
            disabled={currentPage >= images.length - 1}
            onClick={() => setPage(currentPage + 1)}
          >
            <ChevronRight size={16} />
          </Button>
        </div>
        <div className="zoom-tools">
          <Button
            size="icon"
            variant="ghost"
            aria-label={t('zoomOut')}
            onClick={() => setZoom(Math.max(25, zoom - 25))}
          >
            <ZoomOut size={16} />
          </Button>
          <span>{zoom}%</span>
          <Button
            size="icon"
            variant="ghost"
            aria-label={t('zoomIn')}
            onClick={() => setZoom(Math.min(300, zoom + 25))}
          >
            <ZoomIn size={16} />
          </Button>
          <Button size="icon" variant="ghost" aria-label={t('fit')} onClick={() => setZoom(100)}>
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
    </section>
  );
}

function PreviewImage({ src, zoom, alt }: { src: string; zoom: number; alt: string }) {
  const [loaded, setLoaded] = useState(false);
  const reduced = useReducedMotion();
  return (
    <motion.img
      src={src}
      data-testid="preview-image"
      className="preview-image"
      initial={{ width: `${zoom}%`, opacity: 0 }}
      animate={{ width: `${zoom}%`, opacity: loaded ? 1 : 0 }}
      transition={{ duration: reduced ? 0 : 0.2, ease: 'easeOut' }}
      onLoad={() => setLoaded(true)}
      alt={alt}
    />
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
