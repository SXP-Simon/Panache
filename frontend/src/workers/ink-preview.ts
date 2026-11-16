import { filterInk, type InkShape } from '../utils/inkEffects';

let image: Promise<{ alpha: Uint8Array; width: number; height: number }> | null = null;
const worker = self as unknown as {
  onmessage: ((event: MessageEvent<{ source?: string; effects: InkShape }>) => void) | null;
  postMessage: (blob: Blob | null) => void;
};

async function render({ source, effects }: { source?: string; effects: InkShape }) {
  try {
    if (source) {
      image = (async () => {
        const bitmap = await createImageBitmap(await (await fetch(source)).blob());
        try {
          const { width, height } = bitmap;
          const canvas = new OffscreenCanvas(width, height);
          const ctx = canvas.getContext('2d');
          if (!ctx) throw new Error('No ink canvas');
          ctx.drawImage(bitmap, 0, 0);
          const pixels = ctx.getImageData(0, 0, width, height).data;
          const alpha = new Uint8Array(width * height);
          for (let i = 0; i < alpha.length; i++) alpha[i] = pixels[i * 4 + 3] ?? 0;
          return { alpha, width, height };
        } finally {
          bitmap.close();
        }
      })();
    }
    if (!image) throw new Error('Missing ink layer');
    const { alpha, width, height } = await image;
    const mask = filterInk(alpha, width, height, effects);
    const canvas = new OffscreenCanvas(width, height);
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('No ink canvas');
    const data = ctx.createImageData(width, height);
    for (let i = 0; i < mask.length; i++) {
      data.data[i * 4 + 3] = mask[i] ?? 0;
    }
    ctx.putImageData(data, 0, 0);
    worker.postMessage(await canvas.convertToBlob());
  } catch {
    worker.postMessage(null);
  }
}

worker.onmessage = (event) => {
  void render(event.data);
};
