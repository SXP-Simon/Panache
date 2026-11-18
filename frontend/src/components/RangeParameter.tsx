import { useSettingsStore } from '@/features/settings/store';
import { useI18n } from '@/i18n';
import type { NumberField as Field } from '@/models';
import NumberField from './NumberField';

export default function RangeParameter({
  field,
}: {
  field: Field & { max: number; unit: string };
}) {
  const { t } = useI18n();
  const value = useSettingsStore((state) => state.numbers[field.key]);
  const setNumber = useSettingsStore((state) => state.setNumber);
  return (
    <div className="range-parameter">
      <NumberField
        field={{ ...field, testId: `${field.testId}-number` }}
        value={value}
        onChange={(next) => setNumber(field.key, next)}
      />
      <input
        type="range"
        min={field.min}
        max={field.max}
        step={field.step}
        value={value}
        aria-label={t(field.label)}
        aria-valuetext={`${value}${field.unit}`}
        data-testid={field.testId}
        onChange={(event) => setNumber(field.key, event.currentTarget.valueAsNumber)}
      />
    </div>
  );
}
