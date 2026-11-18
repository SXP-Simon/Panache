import { useId } from 'react';
import { useSettingsStore } from '@/features/settings/store';
import { useI18n } from '@/i18n';

const styles = {
  blank: 'paperBlank',
  ruled: 'paperRuled',
  grid: 'paperGrid',
  dots: 'paperDots',
} as const;

export default function PaperStylePicker() {
  const name = useId();
  const { t } = useI18n();
  const selected = useSettingsStore(
    (state) => state.paperPattern || (state.underlined ? 'ruled' : 'blank'),
  );
  const patch = useSettingsStore((state) => state.patch);
  return (
    <fieldset className="paper-style-picker">
      <legend>{t('paperStyle')}</legend>
      <div className="paper-style-options">
        {(Object.keys(styles) as (keyof typeof styles)[]).map((style) => (
          <label key={style} className="paper-style-option">
            <input
              type="radio"
              name={name}
              value={style}
              checked={selected === style}
              data-testid={`paper-style-${style}`}
              onChange={() =>
                patch({
                  underlined: style === 'ruled',
                  paperPattern: style === 'grid' || style === 'dots' ? style : '',
                })
              }
            />
            <span className="paper-style-swatch" data-pattern={style} aria-hidden="true" />
            <span>{t(styles[style])}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}
