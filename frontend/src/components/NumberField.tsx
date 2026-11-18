import { useState } from 'react';
import { validNumber, type NumberField as Field } from '../models';
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
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState({ text: String(value), committed: value });
  return (
    <label className="number-field">
      <span>{t(field.label)}</span>
      <div className="number-control">
        <input
          value={editing && draft.committed === value ? draft.text : String(value)}
          data-testid={field.testId}
          type="number"
          min={field.min}
          max={field.max}
          step={field.step}
          disabled={disabled}
          onFocus={() => {
            setDraft({ text: String(value), committed: value });
            setEditing(true);
          }}
          onBlur={() => setEditing(false)}
          onChange={(event) => {
            const next = event.currentTarget.valueAsNumber;
            const valid =
              Number.isFinite(next) && (field.max === undefined || validNumber(field.key, next));
            setDraft({ text: event.currentTarget.value, committed: valid ? next : value });
            if (valid) onChange(next);
          }}
        />
        {(field.unit || field.step >= 1) && <small>{field.unit ?? 'px'}</small>}
      </div>
    </label>
  );
}
