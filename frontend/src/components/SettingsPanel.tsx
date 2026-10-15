import { useState } from 'react';
import type { Workspace } from '../composables/useWorkspace';
import { useI18n } from '../i18n';
import { mainFields, paperFields, variationFields, strikeFields } from '../models';
import NumberField from './NumberField';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';
import {
  SlidersHorizontal,
  Upload,
  ImagePlus,
  X,
  Save,
  FolderOpen,
  RotateCcw,
} from '../shared/icons';
export default function SettingsPanel({ workspace: w }: { workspace: Workspace }) {
  const { t } = useI18n();
  const [detectOpen, setDetectOpen] = useState(false);
  return (
    <aside className="panel settings-panel" data-testid="settings-panel">
      <header className="panel-heading">
        <div>
          <p className="eyebrow">02 / {t('settingsHint')}</p>
          <h2>
            <SlidersHorizontal size={18} />
            {t('settings')}
          </h2>
        </div>
      </header>
      <div className="settings-body">
        <label className="field-label">
          {t('font')}
          <select
            value={w.selectedFont}
            onChange={(event) => w.patch({ selectedFont: event.currentTarget.value })}
            data-testid="font-select"
          >
            {w.fonts.map((font) => (
              <option key={font} value={font}>
                {font}
              </option>
            ))}
          </select>
        </label>
        <label className="file-button upload-control">
          <Upload size={15} />
          {t('fontUpload')}
          <input
            data-testid="font-file-input"
            type="file"
            accept=".ttf,.otf,.ttc"
            onChange={(event) => {
              const file = event.currentTarget.files?.[0];
              if (file) w.useFont(file);
              event.currentTarget.value = '';
            }}
          />
        </label>
        {w.fontFile && <p className="file-name">{w.fontFile.name}</p>}
        <div className="field-grid">
          {mainFields.map((field) => (
            <NumberField
              key={field.key}
              value={w.numbers[field.key]}
              onChange={(value) => w.setNumber(field.key, value)}
              field={field}
            />
          ))}
        </div>
        <label className="color-field">
          <span>{t('ink')}</span>
          <input
            value={w.ink}
            onChange={(event) => w.patch({ ink: event.currentTarget.value })}
            type="color"
            data-testid="ink-color-input"
          />
        </label>
        <label className="check-row">
          <input
            checked={w.underlined}
            onChange={(event) => w.patch({ underlined: event.currentTarget.checked })}
            type="checkbox"
            data-testid="underlined-checkbox"
          />
          <span>{t('underline')}</span>
        </label>
        <label className="check-row">
          <input
            checked={w.englishSpacing}
            onChange={(event) => w.patch({ englishSpacing: event.currentTarget.checked })}
            type="checkbox"
            data-testid="english-spacing-checkbox"
          />
          <span>{t('englishSpacing')}</span>
        </label>
        <details open>
          <summary>{t('paper')}</summary>
          <label className="file-button upload-control">
            <ImagePlus size={15} />
            {t('background')}
            <input
              data-testid="background-image-input"
              type="file"
              accept="image/*"
              onChange={(event) => {
                const file = event.currentTarget.files?.[0];
                if (file) {
                  w.useBackground(file);
                  setDetectOpen(true);
                }
                event.currentTarget.value = '';
              }}
            />
          </label>
          {w.background && (
            <div className="background-row">
              <span>{w.background.name}</span>
              <Button
                size="icon"
                variant="ghost"
                aria-label={t('removeBackground')}
                data-testid="remove-background-btn"
                onClick={w.removeBackground}
              >
                <X size={14} />
              </Button>
            </div>
          )}
          <div className="field-grid">
            {paperFields.map((field) => (
              <NumberField
                key={field.key}
                value={w.numbers[field.key]}
                onChange={(value) => w.setNumber(field.key, value)}
                field={field}
                disabled={
                  Boolean(w.background) && (field.key === 'width' || field.key === 'height')
                }
              />
            ))}
          </div>
        </details>
        <details>
          <summary>{t('variation')}</summary>
          <div className="field-grid">
            {variationFields.map((field) => (
              <NumberField
                key={field.key}
                value={w.numbers[field.key]}
                onChange={(value) => w.setNumber(field.key, value)}
                field={field}
              />
            ))}
          </div>
        </details>
        <details>
          <summary>{t('strikethrough')}</summary>
          <div className="field-grid">
            {strikeFields.map((field) => (
              <NumberField
                key={field.key}
                value={w.numbers[field.key]}
                onChange={(value) => w.setNumber(field.key, value)}
                field={field}
              />
            ))}
          </div>
        </details>
        <div className="presets-section">
          <label className="field-label">
            {t('presets')}
            <select
              value={w.selectedPreset}
              data-testid="builtin-preset-select"
              onChange={(event) => w.applyPreset(event.currentTarget.value)}
            >
              <option value="" disabled>
                {t('presetChoose')}
              </option>
              <option value="smallUnderlined">{t('presetSmall')}</option>
              <option value="natural">{t('presetNatural')}</option>
              <option value="clean">{t('presetClean')}</option>
            </select>
          </label>
          <div className="preset-actions">
            <Button
              size="small"
              data-testid="save-settings-btn"
              title={t('save')}
              onClick={w.saveSettings}
            >
              <Save size={15} />
              {t('save')}
            </Button>
            <Button
              size="small"
              data-testid="load-settings-btn"
              title={t('load')}
              onClick={w.loadSettings}
            >
              <FolderOpen size={15} />
              {t('load')}
            </Button>
            <Button
              size="icon"
              data-testid="reset-settings-btn"
              aria-label={t('reset')}
              onClick={w.resetSettings}
            >
              <RotateCcw size={15} />
            </Button>
          </div>
        </div>
      </div>
      {detectOpen && (
        <Modal
          title={t('detectTitle')}
          closeLabel={t('close')}
          onClose={() => setDetectOpen(false)}
        >
          <p className="help-text">{t('detectBody')}</p>
          <footer className="modal-actions">
            <Button data-testid="detect-background-cancel" onClick={() => setDetectOpen(false)}>
              {t('cancel')}
            </Button>
            <Button
              variant="primary"
              data-testid="detect-background-confirm"
              onClick={() => {
                setDetectOpen(false);
                void w.detectBackground();
              }}
            >
              {t('confirm')}
            </Button>
          </footer>
        </Modal>
      )}
    </aside>
  );
}
