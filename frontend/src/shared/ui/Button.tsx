import type { ButtonHTMLAttributes } from 'react';
interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'ghost' | 'destructive';
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
      type={type}
      className={`button button--${variant} button--${size} ${className}`}
      {...props}
    />
  );
}
