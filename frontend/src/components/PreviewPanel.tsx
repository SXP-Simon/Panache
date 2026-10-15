import { useState } from 'react';
import type { Workspace } from '../composables/useWorkspace';
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
export default function PreviewPanel({ workspace: w }: { workspace: Workspace }) {
  const { t } = useI18n();
  const [zoom, setZoom] = useState(100);
  const image = w.images[w.currentPage] ?? w.backgroundUrl;
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
          {w.background ? w.background.name : `${w.numbers.width} × ${w.numbers.height}`}
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
            <Button
              variant="primary"
              disabled={w.disabled}
              onClick={() => void w.generate('preview')}
            >
              <Eye size={16} />
              {t('previewAction')}
            </Button>
          </div>
        ) : (
          <img
            src={image}
            data-testid="preview-image"
            className="preview-image"
            style={{ width: `${zoom}%` }}
            alt={t('preview')}
          />
        )}{' '}
        {w.busy && (
          <div className="preview-progress" role="status">
            <LoaderCircle className="spin" size={22} />
            <p>{t('working')}</p>
            <progress value={w.progress} max="100" />
          </div>
        )}
      </div>
      <footer className="preview-tools">
        <div className="page-nav">
          <Button
            size="icon"
            variant="ghost"
            data-testid="preview-prev-btn"
            aria-label={t('previous')}
            disabled={w.currentPage === 0}
            onClick={() => w.patch({ currentPage: w.currentPage - 1 })}
          >
            <ChevronLeft size={16} />
          </Button>
          <span data-testid="preview-page-indicator">
            {w.images.length ? w.currentPage + 1 : 0} / {w.images.length}
          </span>
          <Button
            size="icon"
            variant="ghost"
            data-testid="preview-next-btn"
            aria-label={t('next')}
            disabled={w.currentPage >= w.images.length - 1}
            onClick={() => w.patch({ currentPage: w.currentPage + 1 })}
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
            checked={w.fullPreview}
            onChange={(event) => w.patch({ fullPreview: event.currentTarget.checked })}
            type="checkbox"
            data-testid="full-preview-checkbox"
          />
          <span>{t('fullPreview')}</span>
        </label>
        <div>
          <Button
            data-testid="generate-image-btn"
            disabled={w.disabled}
            onClick={() => void w.generate('zip')}
          >
            <Download size={16} />
            ZIP
          </Button>
          <Button
            variant="primary"
            data-testid="generate-pdf-btn"
            disabled={w.disabled}
            onClick={() => void w.generate('pdf')}
          >
            <FileDown size={16} />
            PDF
          </Button>
        </div>
      </div>
    </section>
  );
}
