import { useEffect, useRef, useState } from 'react';
import { AnimatePresence } from 'motion/react';
import { useShallow } from 'zustand/react/shallow';
import { useDocumentStore } from '@/features/document/store';
import { usePreferencesStore } from '@/features/preferences/store';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import { useNotificationStore } from '@/features/notifications/store';
import { reportFailure } from '@/features/workspace/reportFailure';
import { updateResources } from '@/features/workspace/resourceUpdates';
import { useI18n } from '../i18n';
import { cleanMarkdown } from '@/utils/cleanMarkdown';
import {
  extractLetterEnding,
  formatChineseLetter,
  restoreLetterEnding,
} from '@/utils/chineseLetterFormatter';
import {
  getReferencedImages,
  collapseInlineImages,
  updateInlineImage,
} from '@/utils/inlineImageManager';
import { prepareInlineImage } from '@/utils/prepareInlineImage';
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
export default function EditorPanel() {
  const { text, imageStore, textFileName, setText } = useDocumentStore(
    useShallow((state) => ({
      text: state.text,
      imageStore: state.imageStore,
      textFileName: state.textFileName,
      setText: state.setText,
    })),
  );
  const { importText } = useWorkspaceActions();
  const tableMode = usePreferencesStore((state) => state.tableMode);
  const setTableMode = (value: TableMode) =>
    usePreferencesStore.getState().patch({ tableMode: value });
  const { t } = useI18n();
  const input = useRef<HTMLTextAreaElement>(null);
  const [letter, setLetter] = useState<{
    body: string;
    signature: string;
    date: string;
    detectedEnding: boolean;
  } | null>(null);
  const [backup, setBackup] = useState<{ original: string; formatted: string } | null>(null);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const imagePending = useRef(false);
  const [imageBusy, setImageBusy] = useState(false);
  const [activeImageIndex, setActiveImageIndex] = useState<number | null>(null);
  const images = getReferencedImages(text, imageStore);
  const letterPreview = letter ? formatChineseLetter(letter) : '';
  const activeImage = images.find((image) => image.index === activeImageIndex);
  function editText(value: string) {
    setBackup(null);
    setText(value);
  }
  function insert(value: string) {
    const current = useDocumentStore.getState();
    const start = input.current?.selectionStart ?? current.text.length;
    const end = input.current?.selectionEnd ?? start;
    editText(current.text.slice(0, start) + value + current.text.slice(end));
    const offset = collapseInlineImages(value, current.imageStore).collapsedText.length;
    requestAnimationFrame(() => {
      input.current?.focus();
      input.current?.setSelectionRange(start + offset, start + offset);
    });
  }
  async function addImages(files: File[]) {
    if (files.length === 0) return;
    if (imagePending.current) {
      useNotificationStore.getState().inform('preparingImages');
      return;
    }
    imagePending.current = true;
    setImageBusy(true);
    useNotificationStore.getState().clear();
    const original = useDocumentStore.getState().text;
    const start = input.current?.selectionStart ?? original.length;
    const end = input.current?.selectionEnd ?? start;
    try {
      const values: string[] = [];
      for (const file of files) values.push(`\n![image](${await prepareInlineImage(file)})\n`);
      const value = values.join('');
      let cursor = 0;
      await updateResources(
        (document) => {
          if (document.text !== original) throw new Error('imageDocumentChanged');
          const draft = collapseInlineImages(
            document.text.slice(0, start) + value + document.text.slice(end),
            document.imageStore,
          );
          cursor = start + collapseInlineImages(value, draft.imageStore).collapsedText.length;
          return {
            document: {
              text: draft.collapsedText,
              imageStore: draft.imageStore,
              textFileName: document.textFileName,
            },
          };
        },
        () => mounted.current,
      );
      if (!mounted.current) return;
      setBackup(null);
      requestAnimationFrame(() => {
        input.current?.focus();
        input.current?.setSelectionRange(cursor, cursor);
      });
    } catch (cause) {
      if (!mounted.current) return;
      const key = cause instanceof Error ? cause.message : '';
      useNotificationStore
        .getState()
        .fail(key === 'imageSize' || key === 'imageDocumentChanged' ? key : 'imageInvalid');
    } finally {
      imagePending.current = false;
      if (mounted.current) setImageBusy(false);
    }
  }
  function changeScale(index: number, scale: string) {
    editText(updateInlineImage(useDocumentStore.getState().text, index, scale));
  }
  function removeImage(index: number) {
    editText(updateInlineImage(useDocumentStore.getState().text, index, null));
    if (activeImageIndex === index) setActiveImageIndex(null);
  }
  function openLetter() {
    if (!text.trim()) {
      useNotificationStore.getState().fail('emptyText');
      return;
    }
    const parts = extractLetterEnding(text);
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
          !(event.target instanceof HTMLInputElement) &&
          !(event.target instanceof HTMLTextAreaElement)
        ) {
          event.preventDefault();
          event.stopPropagation();
          input.current?.focus();
          input.current?.setSelectionRange(0, text.length);
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
                void importText(file);
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
              .then((module) =>
                editText(module.convertLatexToUnicode(useDocumentStore.getState().text)),
              )
              .catch(reportFailure);
          }}
        >
          <Sigma size={15} />
          LaTeX
        </Button>
        <Button
          size="small"
          variant="ghost"
          data-testid="clean-markdown-btn"
          title={t('markdownHint')}
          onClick={() => editText(cleanMarkdown(text, { tableMode }))}
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
            accept="image/png,image/jpeg,image/webp,image/gif,image/bmp,image/avif"
            multiple
            disabled={imageBusy}
            onChange={(event) => {
              const files = Array.from(event.currentTarget.files ?? []);
              void addImages(files);
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
            }
          }}
        >
          <option value="list">{t('tableList')}</option>
          <option value="aligned">{t('tableAligned')}</option>
          <option value="raw_pipe">{t('tablePipes')}</option>
          <option value="clean">{t('tableClean')}</option>
        </select>
        {backup !== null && backup.formatted === text && (
          <Button
            size="small"
            variant="ghost"
            data-testid="letter-undo-btn"
            onClick={() => {
              setText(backup.original);
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
        value={text}
        onChange={(event) => editText(event.currentTarget.value)}
        data-testid="text-input"
        className="document-input"
        placeholder={t('editorPlaceholder')}
        aria-label={t('document')}
        spellCheck={false}
        onPaste={(event) => {
          const files = Array.from(event.clipboardData.items)
            .filter((item) => item.type.startsWith('image/'))
            .map((item) => item.getAsFile())
            .filter((file): file is File => file !== null);
          if (files.length) {
            event.preventDefault();
            void addImages(files);
          }
        }}
      />
      {imageBusy && (
        <p className="field-caption" role="status">
          {t('preparingImages')}
        </p>
      )}
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
                  min="10"
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
          {text.length.toLocaleString()} {t('characters')}
        </span>
        <span data-testid="text-file-name">{textFileName}</span>
        <Button size="icon" variant="ghost" aria-label={t('clear')} onClick={() => editText('')}>
          <Trash2 size={15} />
        </Button>
      </footer>
      <AnimatePresence>
        {activeImage && (
          <Modal
            key="image-preview"
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
              {[10, 50, 100, 200, 300, 500, 700].map((scale) => (
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
              min="10"
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
            key="letter"
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
                  onChange={(event) =>
                    setLetter({ ...letter, signature: event.currentTarget.value })
                  }
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
                    original: previous?.formatted === text ? previous.original : text,
                    formatted: letterPreview,
                  }));
                  setText(letterPreview);
                  setLetter(null);
                }}
              >
                {t('apply')}
              </Button>
            </footer>
          </Modal>
        )}
      </AnimatePresence>
    </section>
  );
}
