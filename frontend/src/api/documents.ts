import * as v from 'valibot';
import { fetchApi, parsePayload, readJson } from './client.ts';
import type { BackgroundMargins } from './types.ts';

const marginsSchema = v.object({
  marginLeft: v.pipe(v.number(), v.finite(), v.minValue(0)),
  marginRight: v.pipe(v.number(), v.finite(), v.minValue(0)),
  marginTop: v.pipe(v.number(), v.finite(), v.minValue(0)),
  marginBottom: v.pipe(v.number(), v.finite(), v.minValue(0)),
  lineSpacing: v.pipe(v.number(), v.finite(), v.minValue(Number.MIN_VALUE)),
});
export async function importDocument(file: File, signal?: AbortSignal): Promise<{ text: string }> {
  const body = new FormData();
  body.append('file', file);
  return parsePayload(
    v.object({ text: v.string() }),
    await readJson(
      await fetchApi('/api/textfileprocess', { method: 'POST', body, signal: signal ?? null }),
    ),
  );
}
export async function detectBackground(
  file: File,
  signal?: AbortSignal,
): Promise<BackgroundMargins> {
  const body = new FormData();
  body.append('file', file);
  return parsePayload(
    marginsSchema,
    await readJson(
      await fetchApi('/api/imagefileprocess', { method: 'POST', body, signal: signal ?? null }),
    ),
  );
}
