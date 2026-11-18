import { useState } from 'react';
import { AnimatePresence } from 'motion/react';
import { useIsMutating } from '@tanstack/react-query';
import { useShallow } from 'zustand/react/shallow';
import { useFontsQuery } from '@/api/catalog';
import { useSettingsStore } from '@/features/settings/store';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import type { SettingsSection } from '@/features/workspace/useWorkspaceViewModel';
import { useI18n } from '../i18n';
import {
  mainFields,
  paperFields,
  variationFields,
  strikeFields,
  inkFields,
  latinInkFields,
  latinScaleField,
  isLatinFont,
  latinFonts,
} from '../models';
import ParameterField from './ParameterField';
import RangeParameter from './RangeParameter';
import PaperStylePicker from './PaperStylePicker';
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
const sectionTitles = {
  layout: 'textAndLayout',
  paper: 'paperAndArea',
  ink: 'inkSettings',
  presets: 'presets',
} as const;

export default function SettingsPanel({ section }: { section?: SettingsSection | undefined }) {
  const settings = useSettingsStore(
    useShallow((state) => ({
      selectedFont: state.selectedFont,
      selectedLatinFont: state.selectedLatinFont,
      digitFont: state.digitFont,
      separateLatinInk: state.separateLatinInk,
      latinInk: state.latinInk,
      fontFile: state.fontFile,
      background: state.background,
      englishSpacing: state.englishSpacing,
      ink: state.ink,
      selectedPreset: state.selectedPreset,
      layoutStyle: state.layoutStyle,
      firstLineIndent: state.firstLineIndent,
      monospaced: state.monospaced,
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
  const show = (group: SettingsSection) => section === undefined || section === group;
  return (
    <Card
      as="aside"
      className="settings-panel"
      id="workspace-panel-paper"
      data-testid="settings-panel"
      data-section={section}
    >
      <CardHeader
        title={t(section === undefined ? 'settings' : sectionTitles[section])}
        icon={<SlidersHorizontal size={18} />}
        tone="secondary"
      />
      {section !== 'presets' && (
        <div className="settings-body">
          {show('layout') && (
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
              <SelectField
                label={t('latinFont')}
                value={settings.selectedLatinFont}
                data-testid="latin-font-select"
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  settings.patch({
                    selectedLatinFont: isLatinFont(value) ? value : '',
                  });
                }}
              >
                <option value="">{t('inheritLatinFont')}</option>
                {Object.entries(latinFonts).map(([id, name]) => (
                  <option key={id} value={id}>
                    {name}
                  </option>
                ))}
              </SelectField>
              <SelectField
                label={t('digitFont')}
                value={settings.digitFont}
                data-testid="digit-font-select"
                onChange={(event) =>
                  settings.patch({
                    digitFont: event.currentTarget.value === 'latin' ? 'latin' : 'primary',
                  })
                }
              >
                <option value="primary">{t('digitsFollowPrimary')}</option>
                <option value="latin">{t('digitsFollowLatin')}</option>
              </SelectField>
              <RangeParameter field={latinScaleField} />
              <div className="layout-preset">
                <SelectField
                  label={t('layoutPreset')}
                  value={settings.layoutStyle}
                  data-testid="layout-style-select"
                  aria-describedby="layout-preset-help"
                  onChange={(event) =>
                    settings.patch({
                      layoutStyle:
                        event.currentTarget.value === 'homework' ? 'homework' : 'standard',
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
                  {t(
                    settings.layoutStyle === 'homework'
                      ? 'layoutHomeworkHelp'
                      : 'layoutStandardHelp',
                  )}
                </p>
              </div>
              <div className="field-grid field-grid--compact">
                {mainFields.map((field) => (
                  <ParameterField key={field.key} field={field} />
                ))}
              </div>
              <label className="check-row">
                <input
                  type="checkbox"
                  checked={settings.firstLineIndent}
                  data-testid="first-line-indent-checkbox"
                  onChange={(event) =>
                    settings.patch({ firstLineIndent: event.currentTarget.checked })
                  }
                />
                <span>{t('firstLineIndent')}</span>
              </label>
              <label className="check-row" title={t('monospacedLayoutHint')}>
                <input
                  type="checkbox"
                  checked={settings.monospaced}
                  data-testid="monospaced-layout-checkbox"
                  onChange={(event) => settings.patch({ monospaced: event.currentTarget.checked })}
                />
                <span>{t('monospacedLayout')}</span>
              </label>
              <label className="check-row">
                <input
                  checked={settings.englishSpacing}
                  onChange={(event) =>
                    settings.patch({ englishSpacing: event.currentTarget.checked })
                  }
                  type="checkbox"
                  data-testid="english-spacing-checkbox"
                />
                <span>{t('englishSpacing')}</span>
              </label>
            </SettingsGroup>
          )}
          {show('paper') && (
            <SettingsGroup title={t('paperAndArea')}>
              {!settings.background && <PaperStylePicker />}
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
              <Accordion
                title={t('paperDimensions')}
                testId="paper-settings-toggle"
                initiallyOpen={section === 'paper'}
              >
                <div className="field-grid">
                  {paperFields.map((field) => (
                    <ParameterField key={field.key} field={field} />
                  ))}
                </div>
              </Accordion>
            </SettingsGroup>
          )}
          {show('ink') && (
            <SettingsGroup title={t('inkSettings')}>
              <label className="check-row">
                <input
                  type="checkbox"
                  checked={settings.separateLatinInk}
                  onChange={(event) =>
                    settings.patch({ separateLatinInk: event.currentTarget.checked })
                  }
                  data-testid="separate-latin-ink-checkbox"
                />
                <span>{t('separateLatinInk')}</span>
              </label>
              <label className="color-field">
                <span>{t(settings.separateLatinInk ? 'primaryInkColor' : 'ink')}</span>
                <input
                  value={settings.ink}
                  onChange={(event) => settings.patch({ ink: event.currentTarget.value })}
                  type="color"
                  data-testid="ink-color-input"
                />
              </label>
              <Accordion
                title={t(settings.separateLatinInk ? 'primaryInkEffects' : 'inkEffects')}
                testId="ink-effects-toggle"
                initiallyOpen={section === 'ink'}
              >
                {inkFields.map((field) => (
                  <RangeParameter key={field.key} field={field} />
                ))}
              </Accordion>
              {settings.separateLatinInk && (
                <Accordion
                  title={t('latinInkEffects')}
                  testId="latin-ink-effects-toggle"
                  initiallyOpen
                >
                  <label className="color-field">
                    <span>{t('latinInkColor')}</span>
                    <input
                      type="color"
                      value={settings.latinInk}
                      onChange={(event) => settings.patch({ latinInk: event.currentTarget.value })}
                      data-testid="latin-ink-color-input"
                    />
                  </label>
                  {latinInkFields.map((field) => (
                    <RangeParameter key={field.key} field={field} />
                  ))}
                </Accordion>
              )}
            </SettingsGroup>
          )}
          {show('ink') && (
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
          )}
        </div>
      )}
      {show('presets') && (
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
      )}
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
