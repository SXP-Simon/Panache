import { useEffect, useRef, useState } from 'react';
import { useSettingsStore } from '@/features/settings/store';
import type { InkShape } from '@/utils/inkEffects';

export default function InkPreview({ source, testId }: { source: string; testId: string }) {
  const ink = useSettingsStore((state) => state.ink);
  const opacity = useSettingsStore((state) => state.numbers.ink_opacity);
  const thickness = useSettingsStore((state) => state.numbers.ink_thickness);
  const softness = useSettingsStore((state) => state.numbers.ink_softness);
  const [mask, setMask] = useState(source);
  const send = useRef<((shape: InkShape) => void) | null>(null);

  useEffect(() => {
    const worker = new Worker(new URL('../workers/ink-preview.ts', import.meta.url), {
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
        setMask(source);
        return;
      }
      pending = shape;
      pump();
    };
    worker.onmessage = (event: MessageEvent<Blob | null>) => {
      if (event.data && !original) {
        if (activeUrl) URL.revokeObjectURL(activeUrl);
        activeUrl = URL.createObjectURL(event.data);
        setMask(activeUrl);
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

  return (
    <div
      className="preview-ink-layer"
      aria-hidden="true"
      data-testid={testId}
      style={{ backgroundColor: ink, opacity: opacity / 100, maskImage: `url("${mask}")` }}
    />
  );
}
