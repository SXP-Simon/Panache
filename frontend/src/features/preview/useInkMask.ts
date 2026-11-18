import { useEffect, useRef, useState } from 'react';
import type { InkShape } from '@/utils/inkEffects';

export function useInkMask(source: string | undefined, { thickness, softness }: InkShape) {
  const [filtered, setFiltered] = useState<{ source: string; url: string } | null>(null);
  const send = useRef<((shape: InkShape) => void) | null>(null);

  useEffect(() => {
    if (!source) return;
    const worker = new Worker(new URL('../../workers/ink-preview.ts', import.meta.url), {
      type: 'module',
    });
    let pending: InkShape | null = null;
    let busy = false;
    let first = true;
    let original = true;
    let activeUrl: string | null = null;
    const pump = () => {
      if (busy || !pending) return;
      worker.postMessage({
        ...(first ? { source } : {}),
        effects: pending,
      });
      busy = true;
      first = false;
      pending = null;
    };
    send.current = (shape) => {
      original = !shape.thickness && !shape.softness;
      if (original) {
        pending = null;
        setFiltered(null);
        return;
      }
      pending = shape;
      pump();
    };
    worker.onmessage = (event: MessageEvent<Blob | null>) => {
      if (event.data && !original) {
        if (activeUrl) URL.revokeObjectURL(activeUrl);
        activeUrl = URL.createObjectURL(event.data);
        setFiltered({ source, url: activeUrl });
      }
      busy = false;
      pump();
    };
    return () => {
      send.current = null;
      worker.terminate();
      if (activeUrl) URL.revokeObjectURL(activeUrl);
    };
  }, [source]);
  useEffect(() => {
    send.current?.({ thickness, softness });
  }, [source, thickness, softness]);

  return source && (filtered?.source === source ? filtered.url : source);
}
