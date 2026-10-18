import { useState } from 'react';
import { usePreferencesStore } from './store';
import { useI18n } from '@/i18n';
import Button from '@/shared/ui/Button';

import { DEFAULT_THEME_COLOR } from './themeColors';
const presets = [DEFAULT_THEME_COLOR, '#16866c', '#2563eb', '#8b5cf6', '#d15c37', '#d43779'];
export default function ThemeColorEditor() {
  const { t } = useI18n();
  const color = usePreferencesStore((state) => state.themeColor);
  const patch = usePreferencesStore((state) => state.patch);
  const [draft, setDraft] = useState(color);
  const [error, setError] = useState(false);
  const apply = (next: string) => {
    setDraft(next);
    setError(false);
    patch({ themeColor: next.toLowerCase() });
  };
  return (
    <section className="theme-editor" data-testid="theme-color-editor">
      <h3>{t('themeColor')}</h3>
      <p className="help-text">{t('themeColorHint')}</p>
      <div className="theme-swatches" role="group" aria-label={t('themePresets')}>
        {presets.map((preset) => (
          <button
            key={preset}
            type="button"
            className="theme-swatch"
            style={{ background: preset }}
            aria-label={preset}
            aria-pressed={color === preset}
            data-testid={`theme-preset-${preset.slice(1)}`}
            onClick={() => apply(preset)}
          />
        ))}
      </div>
      <form
        className="theme-color-fields"
        onSubmit={(event) => {
          event.preventDefault();
          if (/^#[0-9a-f]{6}$/i.test(draft)) apply(draft);
          else setError(true);
        }}
      >
        <input
          type="color"
          value={color}
          aria-label={t('themeColor')}
          data-testid="theme-color-picker"
          onChange={(event) => apply(event.target.value)}
        />
        <input
          type="text"
          value={draft}
          aria-label="HEX"
          spellCheck={false}
          maxLength={7}
          aria-invalid={error}
          aria-describedby={error ? 'theme-color-error' : undefined}
          data-testid="theme-color-hex"
          onChange={(event) => {
            setDraft(event.target.value);
            setError(false);
          }}
        />
        <Button type="submit" variant="primary" data-testid="theme-color-apply">
          {t('themeColorApply')}
        </Button>
      </form>
      {error && (
        <p id="theme-color-error" role="alert">
          {t('themeColorInvalid')}
        </p>
      )}
      <Button
        variant="ghost"
        data-testid="theme-color-reset"
        onClick={() => apply(DEFAULT_THEME_COLOR)}
      >
        {t('themeColorReset')}
      </Button>
    </section>
  );
}
