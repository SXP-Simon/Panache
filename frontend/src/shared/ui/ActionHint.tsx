import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { CircleHelp } from '../icons';
import Button from './Button';

export default function ActionHint({
  id,
  text,
  label,
  children,
}: {
  id: string;
  text: string;
  label: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const dismiss = (event: PointerEvent) => {
      if (event.target instanceof Node && !container.current?.contains(event.target))
        setOpen(false);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', dismiss);
    document.addEventListener('keydown', escape);
    return () => {
      document.removeEventListener('pointerdown', dismiss);
      document.removeEventListener('keydown', escape);
    };
  }, [open]);
  return (
    <span
      ref={container}
      className="action-hint"
      onPointerEnter={(event) => {
        if (event.pointerType !== 'touch') setOpen(true);
      }}
      onPointerLeave={() => {
        if (!container.current?.querySelector(':focus-visible')) setOpen(false);
      }}
      onFocusCapture={(event) => {
        if (event.target.matches(':focus-visible')) setOpen(true);
      }}
      onBlurCapture={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false);
      }}
    >
      {children}
      <Button
        size="small"
        variant="ghost"
        className="action-hint-trigger"
        data-testid={`${id}-trigger`}
        aria-label={label}
        aria-describedby={id}
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen((value) => !value)}
      >
        <CircleHelp size={15} />
      </Button>
      <span id={id} role="tooltip" className="action-hint-popup" data-open={open} data-testid={id}>
        <span className="action-hint-bubble">{text}</span>
      </span>
    </span>
  );
}
