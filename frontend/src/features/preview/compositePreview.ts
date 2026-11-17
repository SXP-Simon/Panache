export async function compositePreview(
  paper: HTMLImageElement,
  maskUrl: string,
  color: string,
  opacity: number,
): Promise<Blob> {
  const response = await fetch(maskUrl);
  if (!response.ok) throw new Error('Could not read the ink layer');
  const mask = await createImageBitmap(await response.blob());
  const canvas = document.createElement('canvas');
  try {
    await paper.decode();
    canvas.width = paper.naturalWidth;
    canvas.height = paper.naturalHeight;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Could not open the preview canvas');
    context.drawImage(mask, 0, 0, canvas.width, canvas.height);
    context.globalCompositeOperation = 'source-in';
    context.globalAlpha = opacity;
    context.fillStyle = color;
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.globalCompositeOperation = 'destination-over';
    context.globalAlpha = 1;
    context.drawImage(paper, 0, 0);
    return await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob(
        (png) => (png ? resolve(png) : reject(new Error('Could not encode the preview'))),
        'image/png',
      );
    });
  } finally {
    mask.close();
  }
}
