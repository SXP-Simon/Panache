interface PreviewInk {
  mask: string;
  color: string;
  opacity: number;
}

export async function compositePreview(paper: HTMLImageElement, inks: PreviewInk[]): Promise<Blob> {
  await paper.decode();
  const canvas = document.createElement('canvas');
  const layer = inks.length > 1 ? document.createElement('canvas') : canvas;
  canvas.width = layer.width = paper.naturalWidth;
  canvas.height = layer.height = paper.naturalHeight;
  const context = canvas.getContext('2d');
  const paint = layer.getContext('2d');
  if (!context || !paint) throw new Error('Could not open the preview canvas');
  if (layer !== canvas) context.drawImage(paper, 0, 0);
  for (const ink of inks) {
    const response = await fetch(ink.mask);
    if (!response.ok) throw new Error('Could not read the ink layer');
    const bitmap = await createImageBitmap(await response.blob());
    try {
      paint.clearRect(0, 0, layer.width, layer.height);
      paint.globalCompositeOperation = 'source-over';
      paint.globalAlpha = 1;
      paint.drawImage(bitmap, 0, 0, layer.width, layer.height);
      paint.globalCompositeOperation = 'source-in';
      paint.globalAlpha = ink.opacity;
      paint.fillStyle = ink.color;
      paint.fillRect(0, 0, layer.width, layer.height);
      if (layer !== canvas) context.drawImage(layer, 0, 0);
    } finally {
      bitmap.close();
    }
  }
  if (layer === canvas) {
    context.globalCompositeOperation = 'destination-over';
    context.globalAlpha = 1;
    context.drawImage(paper, 0, 0);
  }
  return await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (png) => (png ? resolve(png) : reject(new Error('Could not encode the preview'))),
      'image/png',
    );
  });
}
