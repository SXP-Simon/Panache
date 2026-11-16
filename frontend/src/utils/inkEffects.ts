export interface InkShape {
  thickness: number;
  softness: number;
}

export function filterInk(
  alpha: Uint8Array,
  width: number,
  height: number,
  effects: InkShape,
): Uint8Array {
  const transform = (source: Uint8Array, radius: number, mode: 'max' | 'min' | 'mean') => {
    const pass = (input: Uint8Array, stride: number, length: number, whole: number) => {
      const result = new Uint8Array(input.length);
      for (let i = 0; i < input.length; i++) {
        const position = Math.floor(i / stride) % length;
        let value = mode === 'min' ? 255 : 0;
        for (let delta = Math.max(-position, -whole); delta <= whole; delta++) {
          const sample = input[i + Math.min(length - 1 - position, delta) * stride] ?? 0;
          value =
            mode === 'min'
              ? Math.min(value, sample)
              : mode === 'max'
                ? Math.max(value, sample)
                : value + sample;
        }
        // Replicate the left or top edge for the same result as the export engine.
        if (mode === 'mean') {
          value += Math.max(0, whole - position) * (input[i - position * stride] ?? 0);
          value = Math.round(value / (whole * 2 + 1));
        }
        result[i] = value;
      }
      return result;
    };
    return pass(pass(source, 1, width, radius), width, height, radius);
  };
  let mask = alpha;
  if (effects.thickness) {
    mask = transform(alpha, Math.abs(effects.thickness), effects.thickness > 0 ? 'max' : 'min');
    if (effects.thickness < 0)
      mask = mask.map((value, i) => Math.round((value * 7 + (alpha[i] ?? 0) * 3) / 10));
  }
  if (effects.softness) mask = transform(mask, effects.softness, 'mean');
  return mask;
}
