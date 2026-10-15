import { useRef, useState } from 'react';
import type { Workspace } from '../composables/useWorkspace';
import { useI18n } from '../i18n';
import { cleanMarkdown } from '@/utils/cleanMarkdown';
import {
  extractLetterEnding,
  formatChineseLetter,
  restoreLetterEnding,
} from '@/utils/chineseLetterFormatter';
import { getReferencedImages, collapseInlineImages } from '@/utils/inlineImageManager';
import type { TableMode } from '@/utils/cleanMarkdown';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';
import {
  FileText,
  Upload,
  ImagePlus,
  Sigma,
  AlignLeft,
  LetterText,
  Undo2,
  Trash2,
  X,
} from '../shared/icons';
export default function EditorPanel({ workspace: w }: { workspace: Workspace }) {
  const { t } = useI18n();
  const input = useRef<HTMLTextAreaElement>(null);
  const [letter, setLetter] = useState<{
    body: string;
    signature: string;
    date: string;
    detectedEnding: boolean;
  } | null>(null);
  const [backup, setBackup] = useState<{ original: string; formatted: string } | null>(null);
  const [tableMode, setTableMode] = useState<TableMode>(() => {
    try {
      const raw: unknown = JSON.parse(localStorage.getItem('markdownTableMode') ?? '"list"');
      return raw === 'aligned' || raw === 'raw_pipe' || raw === 'clean' ? raw : 'list';
    } catch {
      return 'list';
    }
  });
  const [activeImageIndex, setActiveImageIndex] = useState<number | null>(null);
  const images = getReferencedImages(w.text, w.imageStore);
  const letterPreview = letter ? formatChineseLetter(letter) : '';
  const activeImage = images.find((image) => image.index === activeImageIndex);
  function editText(value: string) {
    setBackup(null);
    w.setText(value);
  }
  function insert(value: string) {
    const start = input.current?.selectionStart ?? w.text.length;
    const end = input.current?.selectionEnd ?? start;
    editText(w.text.slice(0, start) + value + w.text.slice(end));
    const offset = collapseInlineImages(value, w.imageStore).collapsedText.length;
    requestAnimationFrame(() => {
      input.current?.focus();
      input.current?.setSelectionRange(start + offset, start + offset);
    });
  }
  async function addImage(file: File) {
    try {
      const data = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
          if (typeof reader.result === 'string') resolve(reader.result);
          else reject(new Error(t('invalidResponse')));
        };
        reader.onerror = () => reject(new Error(t('networkError')));
        reader.readAsDataURL(file);
      });
      insert(`\n![image](${data})\n`);
    } catch (cause) {
      w.fail(cause);
    }
  }
  function changeScale(index: number, scale: string) {
    const pattern = new RegExp(`!\\[(插图[ \\t]*[#:_-]?[ \\t]*${index})(?:\\|[^\\n\\]]+)?\\]`, 'g');
    editText(w.text.replace(pattern, `![插图 ${index}|${scale}%]`));
  }
  function removeImage(index: number) {
    const pattern = new RegExp(`!\\[插图[ \\t]*[#:_-]?[ \\t]*${index}(?:\\|[^\\n\\]]+)?\\]`, 'g');
    editText(w.text.replace(pattern, ''));
    if (activeImageIndex === index) setActiveImageIndex(null);
  }
  function openLetter() {
    if (!w.text.trim()) {
      w.fail(new Error(t('emptyText')));
      return;
    }
    const parts = extractLetterEnding(w.text);
    setLetter({
      body: parts.body,
      signature: parts.signature,
      date: parts.date,
      detectedEnding: parts.detectedEnding,
    });
  }
  return (
    <section
      className="panel editor-panel"
      data-testid="text-panel"
      onKeyDown={(event) => {
        if (
          (event.ctrlKey || event.metaKey) &&
          event.key.toLowerCase() === 'a' &&
          !(event.target instanceof HTMLInputElement)
        ) {
          event.preventDefault();
          event.stopPropagation();
          input.current?.focus();
          input.current?.setSelectionRange(0, w.text.length);
        }
      }}
    >
      <header className="panel-heading">
        <div>
          <p className="eyebrow">01 / {t('documentHint')}</p>
          <h2>
            <FileText size={18} />
            {t('document')}
          </h2>
        </div>
        <label className="icon-button upload-control" title={t('import')}>
          <Upload size={18} />
          <span className="sr-only">{t('import')}</span>
          <input
            data-testid="text-file-input"
            type="file"
            accept=".doc,.docx,.pdf,.txt,.rtf"
            onChange={(event) => {
              const file = event.currentTarget.files?.[0];
              if (file) {
                setBackup(null);
                void w.importText(file);
              }
              event.currentTarget.value = '';
            }}
          />
        </label>
      </header>
      <div className="editor-toolbar">
        <Button
          size="small"
          variant="ghost"
          data-testid="convert-latex-btn"
          onClick={() => {
            void import('@/utils/latexToUnicode')
              .then((module) => editText(module.convertLatexToUnicode(w.text)))
              .catch(w.fail);
          }}
        >
          <Sigma size={15} />
          LaTeX
        </Button>
        <Button
          size="small"
          variant="ghost"
          data-testid="clean-markdown-btn"
          onClick={() => editText(cleanMarkdown(w.text, { tableMode }))}
        >
          <AlignLeft size={15} />
          {t('markdown')}
        </Button>
        <Button size="small" variant="ghost" data-testid="letter-format-btn" onClick={openLetter}>
          <LetterText size={15} />
          {t('letter')}
        </Button>
        <label className="icon-button upload-control" title={t('insertImage')}>
          <ImagePlus size={17} />
          <span className="sr-only">{t('insertImage')}</span>
          <input
            data-testid="inline-image-input"
            type="file"
            accept="image/*"
            onChange={(event) => {
              const file = event.currentTarget.files?.[0];
              if (file) void addImage(file);
              event.currentTarget.value = '';
            }}
          />
        </label>
      </div>
      <div className="editor-options">
        <select
          value={tableMode}
          data-testid="markdown-table-mode"
          aria-label={t('markdown')}
          onChange={(event) => {
            const value = event.currentTarget.value;
            if (
              value === 'list' ||
              value === 'aligned' ||
              value === 'raw_pipe' ||
              value === 'clean'
            ) {
              setTableMode(value);
              try {
                localStorage.setItem('markdownTableMode', JSON.stringify(value));
              } catch {
                w.inform(t('storageUnavailable'));
              }
            }
          }}
        >
          <option value="list">{t('tableList')}</option>
          <option value="aligned">{t('tableAligned')}</option>
          <option value="raw_pipe">{t('tablePipes')}</option>
          <option value="clean">{t('tableClean')}</option>
        </select>
        {backup !== null && backup.formatted === w.text && (
          <Button
            size="small"
            variant="ghost"
            data-testid="letter-undo-btn"
            onClick={() => {
              w.setText(backup.original);
              setBackup(null);
            }}
          >
            <Undo2 size={14} />
            {t('undo')}
          </Button>
        )}
      </div>
      <textarea
        ref={input}
        value={w.text}
        onChange={(event) => editText(event.currentTarget.value)}
        data-testid="text-input"
        className="document-input"
        placeholder={t('editorPlaceholder')}
        aria-label={t('document')}
        spellCheck={false}
        onPaste={(event) => {
          for (const item of event.clipboardData.items) {
            if (item.type.startsWith('image/')) {
              const file = item.getAsFile();
              if (file) {
                event.preventDefault();
                void addImage(file);
                break;
              }
            }
          }
        }}
      />
      {images.length > 0 && (
        <div className="inline-images">
          <p className="field-caption">{t('insertedImages')}</p>
          {images.map((image) => (
            <div key={image.id} className="inline-image-row">
              <button
                className="inline-image-trigger"
                data-testid={`inline-image-preview-${image.index}`}
                type="button"
                aria-label={`${t('imagePreview')} ${image.alt}`}
                onClick={() => setActiveImageIndex(image.index)}
              >
                <img src={image.data} alt={image.alt} />
              </button>
              <label>
                <span>{image.alt}</span>
                <input
                  type="range"
                  data-testid={`inline-image-scale-${image.index}`}
                  min="20"
                  max="700"
                  step="10"
                  value={Number.parseInt(image.scale, 10)}
                  aria-label={t('imageScale')}
                  onChange={(event) => changeScale(image.index, event.currentTarget.value)}
                />
              </label>
              <Button
                variant="ghost"
                size="icon"
                aria-label={t('removeImage')}
                data-testid={`inline-image-remove-${image.index}`}
                onClick={() => removeImage(image.index)}
              >
                <X size={15} />
              </Button>
            </div>
          ))}
        </div>
      )}
      <div className="symbol-strip" data-testid="symbol-strip">
        <span data-testid="symbol-strip-label">{t('symbols')}</span>
        {['⇒', '→', '∈', 'Σ', 'α', 'β', 'π', '²', '³', '√', '≤', '≥', '≠', '|', '∑', '∞'].map(
          (symbol) => (
            <button
              key={symbol}
              type="button"
              data-testid={`quick-symbol-${symbol}`}
              onClick={() => insert(symbol)}
            >
              {symbol}
            </button>
          ),
        )}
      </div>
      <footer className="editor-footer">
        <span>
          {w.text.length.toLocaleString()} {t('characters')}
        </span>
        <span data-testid="text-file-name">{w.textFileName}</span>
        <Button size="icon" variant="ghost" aria-label={t('clear')} onClick={() => editText('')}>
          <Trash2 size={15} />
        </Button>
      </footer>
      {activeImage && (
        <Modal
          title={`${t('imagePreview')} · ${activeImage.alt}`}
          closeLabel={t('close')}
          testId="image-preview-modal"
          onClose={() => setActiveImageIndex(null)}
        >
          <img className="image-preview-full" src={activeImage.data} alt={activeImage.alt} />
          <p className="field-caption">
            {t('imageScale')} · <span data-testid="active-scale-badge">{activeImage.scale}</span>
          </p>
          <div className="image-scale-presets">
            {[50, 100, 200, 300, 500, 700].map((scale) => (
              <Button
                key={scale}
                data-testid={`image-scale-${scale}`}
                size="small"
                onClick={() => changeScale(activeImage.index, String(scale))}
              >
                {scale}%
              </Button>
            ))}
          </div>
          <input
            type="range"
            min="20"
            max="700"
            step="10"
            value={Number.parseInt(activeImage.scale, 10)}
            aria-label={t('imageScale')}
            data-testid="scale-slider"
            onChange={(event) => changeScale(activeImage.index, event.currentTarget.value)}
          />
          <footer className="modal-actions">
            <Button data-testid="modal-delete-btn" onClick={() => removeImage(activeImage.index)}>
              {t('removeImage')}
            </Button>
            <Button
              variant="primary"
              data-testid="modal-close-btn"
              onClick={() => setActiveImageIndex(null)}
            >
              {t('close')}
            </Button>
          </footer>
        </Modal>
      )}
      {letter && (
        <Modal
          title={t('letter')}
          closeLabel={t('close')}
          testId="letter-dialog"
          onClose={() => setLetter(null)}
        >
          <p className="help-text">{t('letterHint')}</p>
          {letter.detectedEnding && (
            <div className="letter-detected">
              <p>{t('letterEndingDetected')}</p>
              <Button
                size="small"
                data-testid="letter-restore-btn"
                onClick={() =>
                  setLetter({
                    body: restoreLetterEnding(letter),
                    signature: '',
                    date: '',
                    detectedEnding: false,
                  })
                }
              >
                {t('letterRestore')}
              </Button>
            </div>
          )}
          <div className="modal-fields">
            <label className="field-label">
              {t('signature')}
              <textarea
                rows={2}
                value={letter.signature}
                onChange={(event) => setLetter({ ...letter, signature: event.currentTarget.value })}
                data-testid="letter-signature-input"
                placeholder={t('signaturePlaceholder')}
              />
            </label>
            <label className="field-label">
              {t('date')}
              <input
                value={letter.date}
                onChange={(event) => setLetter({ ...letter, date: event.currentTarget.value })}
                data-testid="letter-date-input"
                placeholder={t('datePlaceholder')}
              />
            </label>
          </div>
          <p className="field-caption">{t('letterPreview')}</p>
          <pre className="letter-preview" data-testid="letter-preview">
            {letterPreview}
          </pre>
          <footer className="modal-actions">
            <Button data-testid="letter-cancel-btn" onClick={() => setLetter(null)}>
              {t('cancel')}
            </Button>
            <Button
              variant="primary"
              data-testid="letter-apply-btn"
              disabled={!letter.body.trim()}
              onClick={() => {
                setBackup((previous) => ({
                  original: previous?.formatted === w.text ? previous.original : w.text,
                  formatted: letterPreview,
                }));
                w.setText(letterPreview);
                setLetter(null);
              }}
            >
              {t('apply')}
            </Button>
          </footer>
        </Modal>
      )}
    </section>
  );
}
