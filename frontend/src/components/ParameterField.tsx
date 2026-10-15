import { useSettingsStore } from '@/features/settings/store';
import type { NumberField as Field } from '@/models';
import NumberField from './NumberField';

export default function ParameterField({ field }: { field: Field }) {
  const value = useSettingsStore((state) => state.numbers[field.key]);
  const disabled = useSettingsStore(
    (state) => Boolean(state.background) && (field.key === 'width' || field.key === 'height'),
  );
  const setNumber = useSettingsStore((state) => state.setNumber);
  return (
    <NumberField
      field={field}
      value={value}
      disabled={disabled}
      onChange={(next) => setNumber(field.key, next)}
    />
  );
}
