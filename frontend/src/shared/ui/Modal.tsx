import { useEffect, useId, useRef } from 'react';
import type { ReactNode } from 'react';
import Button from './Button';
import { X } from '../icons';
export default function Modal({
  title,
  closeLabel,
  onClose,
  children,
  testId,
}: {
  title: string;
  closeLabel: string;
  onClose: () => void;
  children: ReactNode;
  testId?: string;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  useEffect(() => {
    const element = dialog.current;
    const previous = document.activeElement;
    element?.showModal();
    return () => {
      element?.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  }, []);
  return (
    <dialog
      ref={dialog}
      className="modal"
      data-testid={testId}
      aria-labelledby={titleId}
      onKeyDown={(event) => {
        if (event.key !== 'Tab') return;
        const element = dialog.current;
        if (!element) return;
        const controls = Array.from(
          element.querySelectorAll<HTMLElement>(
            'a[href], button, input, select, textarea, [tabindex], [contenteditable="true"]',
          ),
        ).filter(
          (control) =>
            control.tabIndex >= 0 &&
            !control.matches(':disabled') &&
            !control.closest('[hidden], [inert]') &&
            control.getClientRects().length > 0 &&
            getComputedStyle(control).visibility !== 'hidden',
        );
        const first = controls[0];
        const last = controls.at(-1);
        if (!first || !last) {
          event.preventDefault();
          element.focus();
        } else if (
          event.shiftKey &&
          (document.activeElement === first || !element.contains(document.activeElement))
        ) {
          event.preventDefault();
          last.focus();
        } else if (
          !event.shiftKey &&
          (document.activeElement === last || !element.contains(document.activeElement))
        ) {
          event.preventDefault();
          first.focus();
        }
      }}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClick={(event) => {
        if (event.target === dialog.current) {
          const bounds = dialog.current.getBoundingClientRect();
          if (
            event.clientX < bounds.left ||
            event.clientX > bounds.right ||
            event.clientY < bounds.top ||
            event.clientY > bounds.bottom
          )
            onClose();
        }
      }}
    >
      <header className="modal-heading">
        <h2 id={titleId}>{title}</h2>
        <Button size="icon" variant="ghost" aria-label={closeLabel} onClick={onClose}>
          <X size={18} />
        </Button>
      </header>
      {children}
    </dialog>
  );
}
