import { useId, useState } from 'react';
import type { ReactNode } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import { ChevronRight } from '../icons';

export default function Accordion({
  title,
  testId,
  children,
}: {
  title: string;
  testId: string;
  children: ReactNode;
}) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const [hidden, setHidden] = useState(true);
  const reduced = useReducedMotion();
  return (
    <section className="settings-accordion" data-state={open ? 'open' : 'closed'}>
      <button
        type="button"
        className="accordion-trigger"
        id={`${id}-trigger`}
        aria-controls={`${id}-content`}
        aria-expanded={open}
        data-testid={testId}
        onClick={() => {
          if (!open) setHidden(false);
          setOpen(!open);
        }}
      >
        <span>{title}</span>
        <motion.span
          className="accordion-chevron"
          aria-hidden="true"
          initial={false}
          animate={{ rotate: open ? 90 : 0 }}
          transition={reduced ? { duration: 0 } : { type: 'spring', stiffness: 300, damping: 25 }}
        >
          <ChevronRight size={16} />
        </motion.span>
      </button>
      <motion.div
        className="accordion-content"
        id={`${id}-content`}
        role="region"
        aria-labelledby={`${id}-trigger`}
        aria-hidden={!open}
        inert={!open}
        data-testid={`${testId}-content`}
        initial={false}
        animate={{ height: open ? 'auto' : 0, opacity: open ? 1 : 0 }}
        style={{ visibility: hidden ? 'hidden' : 'visible' }}
        transition={
          reduced
            ? { duration: 0 }
            : {
                height: { type: 'spring', stiffness: 300, damping: 25 },
                opacity: { duration: 0.2, ease: 'easeOut' },
              }
        }
        onAnimationComplete={() => {
          if (!open) setHidden(true);
        }}
      >
        <div className="accordion-inner">{children}</div>
      </motion.div>
    </section>
  );
}
