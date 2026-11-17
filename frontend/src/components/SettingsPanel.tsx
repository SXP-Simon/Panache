import { useState } from 'react';
import { AnimatePresence } from 'motion/react';
import { useIsMutating } from '@tanstack/react-query';
import { useShallow } from 'zustand/react/shallow';
import { useFontsQuery } from '@/api/catalog';
import { useSettingsStore } from '@/features/settings/store';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import { useI18n } from '../i18n';
import { mainFields, paperFields, variationFields, strikeFields, inkFields } from '../models';
import ParameterField from './ParameterField';
import { Card, CardHeader } from '../shared/ui/Card';
import { FileField, SelectField } from '../shared/ui/Field';
import Button from '../shared/ui/Button';
import Modal from '../shared/ui/Modal';
import Accordion from '../shared/ui/Accordion';
import SettingsGroup from '../shared/ui/SettingsGroup';
import PaperAreaControl from './PaperAreaControl';
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
      layoutStyle: state.layoutStyle,
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
    <Card as="aside" className="settings-panel" data-testid="settings-panel">
      <CardHeader title={t('settings')} icon={<SlidersHorizontal size={18} />} tone="secondary" />
      <div className="settings-body">
        <SettingsGroup title={t('textAndLayout')}>
          <SelectField
            label={t('font')}
            value={settings.selectedFont}
            onChange={(event) => settings.patch({ selectedFont: event.currentTarget.value })}
            data-testid="font-select"
          >
            {fonts.map((font) => (
              <option key={font} value={font}>
                {font}
              </option>
            ))}
          </SelectField>
          <FileField
            label={t('fontUpload')}
            icon={<Upload size={15} />}
            accept=".ttf,.otf,.ttc"
            testId="font-file-input"
            onPick={(file) => void uploadFont(file)}
          />
          {settings.fontFile && <p className="file-name">{settings.fontFile.name}</p>}
          <div className="layout-preset">
            <SelectField
              label={t('layoutPreset')}
              value={settings.layoutStyle}
              data-testid="layout-style-select"
              aria-describedby="layout-preset-help"
              onChange={(event) =>
                settings.patch({
                  layoutStyle: event.currentTarget.value === 'homework' ? 'homework' : 'standard',
                })
              }
            >
              <option value="standard">{t('layoutStandard')}</option>
              <option value="homework">{t('layoutHomework')}</option>
            </SelectField>
            <p
              id="layout-preset-help"
              className="layout-preset-help"
              data-testid="layout-preset-help"
            >
              {t(settings.layoutStyle === 'homework' ? 'layoutHomeworkHelp' : 'layoutStandardHelp')}
            </p>
          </div>
          <div className="field-grid field-grid--compact">
            {mainFields.map((field) => (
              <ParameterField key={field.key} field={field} />
            ))}
          </div>
          <label className="check-row">
            <input
              checked={settings.englishSpacing}
              onChange={(event) => settings.patch({ englishSpacing: event.currentTarget.checked })}
              type="checkbox"
              data-testid="english-spacing-checkbox"
            />
            <span>{t('englishSpacing')}</span>
          </label>
        </SettingsGroup>
        <SettingsGroup title={t('paperAndArea')}>
          <label className="check-row">
            <input
              checked={settings.underlined}
              onChange={(event) => settings.patch({ underlined: event.currentTarget.checked })}
              type="checkbox"
              data-testid="underlined-checkbox"
            />
            <span>{t('underline')}</span>
          </label>
          <FileField
            label={t('background')}
            icon={<ImagePlus size={15} />}
            accept="image/*"
            testId="background-image-input"
            onPick={(file) => {
              void uploadBackground(file).then((applied) => {
                if (applied) setDetectOpen(true);
              });
            }}
          />
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
              <div className="background-actions">
                <PaperAreaControl />
                <Button
                  size="small"
                  data-testid="redetect-background-btn"
                  disabled={detecting}
                  title={t('detectHelp')}
                  onClick={() => void detectBackground()}
                >
                  {detecting ? (
                    <LoaderCircle size={15} className="spin" />
                  ) : (
                    <RotateCcw size={15} />
                  )}
                  {t(detecting ? 'detectingBackground' : 'redetectBackground')}
                </Button>
              </div>
            </>
          )}
          <Accordion title={t('paperDimensions')} testId="paper-settings-toggle">
            <div className="field-grid">
              {paperFields.map((field) => (
                <ParameterField key={field.key} field={field} />
              ))}
            </div>
          </Accordion>
        </SettingsGroup>
        <SettingsGroup title={t('inkSettings')}>
          <label className="color-field">
            <span>{t('ink')}</span>
            <input
              value={settings.ink}
              onChange={(event) => settings.patch({ ink: event.currentTarget.value })}
              type="color"
              data-testid="ink-color-input"
            />
          </label>
          <Accordion title={t('inkEffects')} testId="ink-effects-toggle">
            {inkFields.map((field) => (
              <InkSlider key={field.key} field={field} />
            ))}
          </Accordion>
        </SettingsGroup>
        <SettingsGroup title={t('advancedInk')}>
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
        </SettingsGroup>
        <SettingsGroup title={t('presets')} className="presets-section">
          <div className="preset-controls">
            <SelectField
              label={t('presets')}
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
            </SelectField>
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
        </SettingsGroup>
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
    </Card>
  );
}

function InkSlider({ field }: { field: (typeof inkFields)[number] }) {
  const { t } = useI18n();
  const value = useSettingsStore((state) => state.numbers[field.key]);
  const setNumber = useSettingsStore((state) => state.setNumber);
  return (
    <label className="field-label">
      <span>
        {t(field.label)} {value.toFixed(field.step === 1 ? 0 : 1)}
        {field.key === 'ink_opacity' ? '%' : ' px'}
      </span>
      <input
        type="range"
        min={field.min}
        max={field.max}
        step={field.step}
        value={value}
        data-testid={field.testId}
        onChange={(event) => setNumber(field.key, event.currentTarget.valueAsNumber)}
      />
    </label>
  );
}
