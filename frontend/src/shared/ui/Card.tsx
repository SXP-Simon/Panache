import type { HTMLAttributes, ReactNode } from 'react';

type CardProps = HTMLAttributes<HTMLElement> & { as?: 'section' | 'aside' };

export function Card({ as: Surface = 'section', className = '', ...props }: CardProps) {
  return <Surface data-slot="card" className={`panel ${className}`} {...props} />;
}

interface CardHeaderProps {
  title: string;
  icon: ReactNode;
  tone?: 'primary' | 'secondary';
  children?: ReactNode;
}

export function CardHeader({ title, icon, tone = 'primary', children }: CardHeaderProps) {
  return (
    <header data-slot="card-header" data-tone={tone} className="panel-heading">
      <h2 data-slot="card-title">
        <span data-slot="card-icon" className="panel-icon" aria-hidden="true">
          {icon}
        </span>
        {title}
      </h2>
      {children}
    </header>
  );
}
