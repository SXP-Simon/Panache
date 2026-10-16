/** Decode before insertion; bound camera photos and normalize browser-only formats for the renderer. */
export async function prepareInlineImage(file: File): Promise<string> {
  if (!file.size || file.size > 20 * 1024 * 1024) throw new Error('imageSize');
  if (file.type && !/^image\/(?:png|jpeg|webp|gif|bmp|x-ms-bmp|avif)$/i.test(file.type)) {
    throw new Error('imageInvalid');
  }
  const url = URL.createObjectURL(file);
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    const { naturalWidth: width, naturalHeight: height } = image;
    if (!width || !height || width * height > 40_000_000) throw new Error('imageSize');
    const signature = new Uint8Array(await file.slice(0, 8).arrayBuffer());
    const png = [137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => signature[index] === byte);
    if (file.type === 'image/png' && png && Math.max(width, height) <= 4000) {
      return await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () =>
          typeof reader.result === 'string'
            ? resolve(reader.result)
            : reject(new Error('imageInvalid'));
        reader.onerror = () => reject(new Error('imageInvalid'));
        reader.onabort = () => reject(new Error('imageInvalid'));
        reader.readAsDataURL(file);
      });
    }
    const factor = Math.min(1, 4000 / Math.max(width, height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(width * factor));
    canvas.height = Math.max(1, Math.round(height * factor));
    const context = canvas.getContext('2d');
    if (!context) throw new Error('imageInvalid');
    for (let attempt = 0; attempt < 3; attempt += 1) {
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      const data = canvas.toDataURL('image/png');
      if (data.length < 28 * 1024 * 1024) return data;
      canvas.width = Math.max(1, Math.floor(canvas.width / 2));
      canvas.height = Math.max(1, Math.floor(canvas.height / 2));
    }
    throw new Error('imageSize');
  } finally {
    URL.revokeObjectURL(url);
  }
}
