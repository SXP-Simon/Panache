import type { NumberField as Field } from '../models';
import { useI18n } from '../i18n';
export default function NumberField({
  field,
  value,
  onChange,
  disabled = false,
}: {
  field: Field;
  value: number;
  onChange: (value: number) => void;
  disabled?: boolean;
}) {
  const { t } = useI18n();
  return (
    <label className="number-field">
      <span>{t(field.label)}</span>
      <div className="number-control">
        <input
          value={value}
          data-testid={field.testId}
          type="number"
          min={field.min}
          step={field.step}
          disabled={disabled}
          onChange={(event) => {
            if (Number.isFinite(event.currentTarget.valueAsNumber))
              onChange(event.currentTarget.valueAsNumber);
          }}
        />
        {field.step >= 1 && <small>px</small>}
      </div>
    </label>
  );
}
