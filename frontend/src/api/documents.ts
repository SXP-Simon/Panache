import * as v from 'valibot';
import { fetchApi, parsePayload, readJson } from './client.ts';
import type { BackgroundMargins } from './types.ts';

const marginsSchema = v.object({
  marginLeft: v.pipe(v.number(), v.finite()),
  marginRight: v.pipe(v.number(), v.finite()),
  marginTop: v.pipe(v.number(), v.finite()),
  marginBottom: v.pipe(v.number(), v.finite()),
  lineSpacing: v.pipe(v.number(), v.finite()),
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
