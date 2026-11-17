import { useId } from 'react';
import type { ReactNode } from 'react';

export default function SettingsGroup({
  title,
  children,
  className = '',
}: {
  title: string;
  children: ReactNode;
  className?: string;
}) {
  const label = useId();
  return (
    <section className={`settings-group ${className}`} aria-labelledby={label}>
      <h3 className="settings-group-heading" id={label}>
        {title}
      </h3>
      <div className="settings-group-body">{children}</div>
    </section>
  );
}
