import { useState } from 'react';
import { AnimatePresence } from 'motion/react';
import { useIsMutating } from '@tanstack/react-query';
import { useShallow } from 'zustand/react/shallow';
import { useFontsQuery } from '@/api/catalog';
import { useSettingsStore } from '@/features/settings/store';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import { useI18n } from '../i18n';
import { mainFields, paperFields, variationFields, strikeFields } from '../models';
import ParameterField from './ParameterField';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';
import Accordion from '../shared/ui/Accordion';
import {
  SlidersHorizontal,
  Upload,
  ImagePlus,
  X,
  Save,
  FolderOpen,
  RotateCcw,
  LoaderCircle,
} from '../shared/icons';
export default function SettingsPanel() {
  const settings = useSettingsStore(
    useShallow((state) => ({
      selectedFont: state.selectedFont,
      fontFile: state.fontFile,
      background: state.background,
      underlined: state.underlined,
      englishSpacing: state.englishSpacing,
      ink: state.ink,
      selectedPreset: state.selectedPreset,
      patch: state.patch,
    })),
  );
  const {
    saveSettings,
    loadSettings,
    resetSettings,
    applyPreset,
    detectBackground,
    uploadFont,
    uploadBackground,
    removeBackground,
  } = useWorkspaceActions();
  const catalog = useFontsQuery().data ?? [];
  const fonts =
    settings.fontFile && !catalog.includes(settings.fontFile.name)
      ? [...catalog, settings.fontFile.name]
      : catalog;
  const { t } = useI18n();
  const [detectOpen, setDetectOpen] = useState(false);
  const detecting = useIsMutating({ mutationKey: ['documents', 'detect-background'] }) > 0;
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
            value={settings.selectedFont}
            onChange={(event) => settings.patch({ selectedFont: event.currentTarget.value })}
            data-testid="font-select"
          >
            {fonts.map((font) => (
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
              if (file) void uploadFont(file);
              event.currentTarget.value = '';
            }}
          />
        </label>
        {settings.fontFile && <p className="file-name">{settings.fontFile.name}</p>}
        <div className="field-grid">
          {mainFields.map((field) => (
            <ParameterField key={field.key} field={field} />
          ))}
        </div>
        <label className="color-field">
          <span>{t('ink')}</span>
          <input
            value={settings.ink}
            onChange={(event) => settings.patch({ ink: event.currentTarget.value })}
            type="color"
            data-testid="ink-color-input"
          />
        </label>
        <label className="check-row">
          <input
            checked={settings.underlined}
            onChange={(event) => settings.patch({ underlined: event.currentTarget.checked })}
            type="checkbox"
            data-testid="underlined-checkbox"
          />
          <span>{t('underline')}</span>
        </label>
        <label className="check-row">
          <input
            checked={settings.englishSpacing}
            onChange={(event) => settings.patch({ englishSpacing: event.currentTarget.checked })}
            type="checkbox"
            data-testid="english-spacing-checkbox"
          />
          <span>{t('englishSpacing')}</span>
        </label>
        <Accordion title={t('paper')} testId="paper-settings-toggle">
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
                  void uploadBackground(file).then((applied) => {
                    if (applied) setDetectOpen(true);
                  });
                }
                event.currentTarget.value = '';
              }}
            />
          </label>
          {settings.background && (
            <>
              <div className="background-row">
                <span>{settings.background.name}</span>
                <Button
                  size="icon"
                  variant="ghost"
                  aria-label={t('removeBackground')}
                  data-testid="remove-background-btn"
                  onClick={removeBackground}
                >
                  <X size={14} />
                </Button>
              </div>
              <Button
                size="small"
                className="background-detect"
                data-testid="redetect-background-btn"
                disabled={detecting}
                title={t('detectHelp')}
                onClick={() => void detectBackground()}
              >
                {detecting ? <LoaderCircle size={15} className="spin" /> : <RotateCcw size={15} />}
                {t(detecting ? 'detectingBackground' : 'redetectBackground')}
              </Button>
            </>
          )}
          <div className="field-grid">
            {paperFields.map((field) => (
              <ParameterField key={field.key} field={field} />
            ))}
          </div>
        </Accordion>
        <Accordion title={t('variation')} testId="variation-settings-toggle">
          <div className="field-grid">
            {variationFields.map((field) => (
              <ParameterField key={field.key} field={field} />
            ))}
          </div>
        </Accordion>
        <Accordion title={t('strikethrough')} testId="strike-settings-toggle">
          <div className="field-grid">
            {strikeFields.map((field) => (
              <ParameterField key={field.key} field={field} />
            ))}
          </div>
        </Accordion>
        <div className="presets-section">
          <label className="field-label">
            {t('presets')}
            <select
              value={settings.selectedPreset}
              data-testid="builtin-preset-select"
              onChange={(event) => applyPreset(event.currentTarget.value)}
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
              onClick={() => void saveSettings()}
            >
              <Save size={15} />
              {t('save')}
            </Button>
            <Button
              size="small"
              data-testid="load-settings-btn"
              title={t('load')}
              onClick={() => void loadSettings()}
            >
              <FolderOpen size={15} />
              {t('load')}
            </Button>
            <Button
              size="icon"
              data-testid="reset-settings-btn"
              aria-label={t('reset')}
              onClick={resetSettings}
            >
              <RotateCcw size={15} />
            </Button>
          </div>
        </div>
      </div>
      <AnimatePresence>
        {detectOpen && (
          <Modal
            key="detect-background"
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
                disabled={detecting}
                onClick={() => {
                  setDetectOpen(false);
                  void detectBackground();
                }}
              >
                {t('confirm')}
              </Button>
            </footer>
          </Modal>
        )}
      </AnimatePresence>
    </aside>
  );
}
