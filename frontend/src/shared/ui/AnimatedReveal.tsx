import type { ReactNode } from 'react';
import { motion, useIsPresent, useReducedMotion } from 'motion/react';

export default function AnimatedReveal({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  const present = useIsPresent();
  return (
    <motion.div
      className="animated-reveal"
      inert={!present}
      initial={{ height: 0, opacity: 0 }}
      animate={{ height: 'auto', opacity: 1 }}
      exit={{ height: 0, opacity: 0 }}
      transition={
        reduced
          ? { duration: 0 }
          : {
              height: { type: 'spring', stiffness: 300, damping: 25 },
              opacity: { duration: 0.2, ease: 'easeOut' },
            }
      }
    >
      {children}
    </motion.div>
  );
}
