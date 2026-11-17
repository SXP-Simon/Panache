import type { ReactNode, SelectHTMLAttributes } from 'react';

export function SelectField({
  label,
  ...props
}: SelectHTMLAttributes<HTMLSelectElement> & { label: string }) {
  return (
    <label className="field-label" data-slot="field">
      <span>{label}</span>
      <select data-slot="select" {...props} />
    </label>
  );
}

interface FileFieldProps {
  label: string;
  icon: ReactNode;
  accept: string;
  testId: string;
  onPick: (file: File) => void;
}

export function FileField({ label, icon, accept, testId, onPick }: FileFieldProps) {
  return (
    <label className="file-button upload-control" data-slot="file-field">
      <span aria-hidden="true">{icon}</span>
      {label}
      <input
        data-testid={testId}
        type="file"
        accept={accept}
        onChange={(event) => {
          const file = event.currentTarget.files?.[0];
          event.currentTarget.value = '';
          if (file) onPick(file);
        }}
      />
    </label>
  );
}
