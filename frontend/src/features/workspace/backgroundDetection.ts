import { ApiError } from '../../api/client.ts';
import type { BackgroundMargins } from '../../api/types.ts';

/** Convert image measurements into layout coordinates without using the previous settings. */
export function detectedLayout(margins: BackgroundMargins) {
  const spacing = margins.lineSpacing;
  const first =
    margins.firstBaseline ??
    margins.marginTop + Math.max(0, Math.ceil((spacing - margins.marginTop) / spacing)) * spacing;
  const top = margins.layoutTopMargin ?? Math.max(0, first - spacing);
  const bottom = margins.layoutBottomMargin ?? margins.marginBottom;
  if (
    !Number.isFinite(top) ||
    top < 0 ||
    Math.abs(top + spacing - first) > 1 ||
    (margins.imageWidth !== undefined &&
      margins.marginLeft + margins.marginRight >= margins.imageWidth) ||
    (margins.imageHeight !== undefined && top + spacing + bottom > margins.imageHeight)
  )
    throw new ApiError('invalidResponse');
  return {
    left_margin: margins.marginLeft,
    right_margin: margins.marginRight,
    top_margin: top,
    bottom_margin: bottom,
    line_spacing: spacing,
  };
}

/** Decode only the corrected PNG supplied by the detector; never fetch an arbitrary URL. */
export async function correctedPaper(original: File, margins: BackgroundMargins): Promise<File> {
  if (margins.correctedBackground === undefined) return original;
  try {
    const binary = atob(margins.correctedBackground);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (!signature.every((value, index) => bytes[index] === value))
      throw new ApiError('invalidResponse');
    const file = new File([bytes], `${original.name.replace(/\.[^.]*$/, '')}.png`, {
      type: 'image/png',
    });
    const bitmap = await createImageBitmap(file);
    try {
      if (bitmap.width !== margins.imageWidth || bitmap.height !== margins.imageHeight)
        throw new ApiError('invalidResponse');
    } finally {
      bitmap.close();
    }
    return file;
  } catch (cause) {
    throw new ApiError('invalidResponse', { cause });
  }
}
