import { useState } from 'react';
import { usePreferencesStore } from './store';
import { useI18n } from '@/i18n';
import Button from '@/shared/ui/Button';

import { DEFAULT_SECONDARY_COLOR, DEFAULT_THEME_COLOR } from './themeColors';

export default function ThemeColorEditor() {
  const { t } = useI18n();
  const primary = usePreferencesStore((state) => state.themeColor);
  const secondary = usePreferencesStore((state) => state.secondaryColor);
  const patch = usePreferencesStore((state) => state.patch);
  return (
    <section className="theme-editor" data-testid="theme-color-editor">
      <h3>{t('themeColor')}</h3>
      <p className="help-text">{t('themeColorHint')}</p>
      <ThemeColorField
        label={t('themePrimaryColor')}
        id="theme-color"
        color={primary}
        defaultColor={DEFAULT_THEME_COLOR}
        onChange={(themeColor) => patch({ themeColor })}
      />
      <ThemeColorField
        label={t('themeSecondaryColor')}
        id="theme-secondary-color"
        color={secondary}
        defaultColor={DEFAULT_SECONDARY_COLOR}
        onChange={(secondaryColor) => patch({ secondaryColor })}
      />
    </section>
  );
}

function ThemeColorField({
  label,
  id,
  color,
  defaultColor,
  onChange,
}: {
  label: string;
  id: string;
  color: string;
  defaultColor: string;
  onChange: (color: string) => void;
}) {
  const { t } = useI18n();
  const [draft, setDraft] = useState(color);
  const [error, setError] = useState(false);
  const presets = [defaultColor, '#477696', '#538577', '#81668f', '#ac6c55'];
  const apply = (next: string) => {
    setDraft(next);
    setError(false);
    onChange(next.toLowerCase());
  };
  return (
    <fieldset className="theme-color-group">
      <legend>{label}</legend>
      <div className="theme-swatches" role="group" aria-label={t('themePresets')}>
        {presets.map((preset) => (
          <button
            key={preset}
            type="button"
            className="theme-swatch"
            style={{ background: preset }}
            aria-label={preset}
            aria-pressed={color === preset}
            data-testid={`${id}-preset-${preset.slice(1)}`}
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
          aria-label={label}
          data-testid={`${id}-picker`}
          onChange={(event) => apply(event.target.value)}
        />
        <input
          type="text"
          value={draft}
          aria-label={`${label} HEX`}
          spellCheck={false}
          maxLength={7}
          aria-invalid={error}
          aria-describedby={error ? `${id}-error` : undefined}
          data-testid={`${id}-hex`}
          onChange={(event) => {
            setDraft(event.target.value);
            setError(false);
          }}
        />
        <Button
          type="submit"
          variant={id === 'theme-color' ? 'primary' : 'tonal'}
          data-testid={`${id}-apply`}
        >
          {t('themeColorApply')}
        </Button>
      </form>
      {error && (
        <p id={`${id}-error`} role="alert">
          {t('themeColorInvalid')}
        </p>
      )}
      <Button variant="ghost" data-testid={`${id}-reset`} onClick={() => apply(defaultColor)}>
        {t('themeColorReset')}
      </Button>
    </fieldset>
  );
}
