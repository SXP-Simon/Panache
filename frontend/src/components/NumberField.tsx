import { useState } from 'react';
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
          step={field.step}
          disabled={disabled}
          onFocus={() => {
            setDraft({ text: String(value), committed: value });
            setEditing(true);
          }}
          onBlur={() => setEditing(false)}
          onChange={(event) => {
            const next = event.currentTarget.valueAsNumber;
            const finite = Number.isFinite(next);
            setDraft({ text: event.currentTarget.value, committed: finite ? next : value });
            if (finite) onChange(next);
          }}
        />
        {field.step >= 1 && <small>px</small>}
      </div>
    </label>
  );
}
