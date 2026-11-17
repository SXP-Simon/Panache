import type { ButtonHTMLAttributes } from 'react';
interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'tonal' | 'ghost' | 'destructive';
  size?: 'normal' | 'small' | 'icon';
}
export default function Button({
  variant = 'secondary',
  size = 'normal',
  type = 'button',
  className = '',
  ...props
}: Props) {
  return (
    <button
      data-slot="button"
      data-variant={variant}
      type={type}
      className={`button button--${variant} button--${size} ${className}`}
      {...props}
    />
  );
}
