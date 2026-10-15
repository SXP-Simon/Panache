import { queryOptions } from '@tanstack/react-query';
import * as v from 'valibot';
import { expandInlineImages } from '../utils/inlineImageManager.ts';
import { ApiError, fetchApi, parsePayload, readJson } from './client.ts';
import type { GenerationMode, GenerationResult, GenerationSnapshot } from './types.ts';

const nullableCount = v.optional(v.nullable(v.pipe(v.number(), v.finite(), v.minValue(0))));
export const taskSchema = v.object({
  task_id: v.optional(v.string()),
  task_status: v.picklist(['pending', 'processing', 'completed', 'failed']),
  task_stage: v.optional(v.string()),
  task_message: v.optional(v.string()),
  task_progress: v.optional(v.pipe(v.number(), v.finite(), v.minValue(0), v.maxValue(100))),
  error_message: v.optional(v.string()),
  queue_pending_count: nullableCount,
  queue_ahead_count: nullableCount,
  processing_count: nullableCount,
});
export type GenerationTask = v.InferOutput<typeof taskSchema>;
export const generationKeys = {
  active: ['generation', 'active'] as const,
  mutation: ['generation', 'run'] as const,
  task: (id: string) => ['generation', 'task', id] as const,
  result: (id: string, mode: GenerationMode) => ['generation', 'result', id, mode] as const,
};
export function generationFormData(snapshot: GenerationSnapshot, mode: GenerationMode): FormData {
  const body = new FormData();
  body.append('text', expandInlineImages(snapshot.text, snapshot.imageStore));
  for (const [key, value] of Object.entries(snapshot.numbers)) {
    if (snapshot.background && (key === 'width' || key === 'height')) continue;
    body.append(key, String(value));
  }
  body.append('font_option', snapshot.selectedFont);
  if (snapshot.fontFile?.name === snapshot.selectedFont)
    body.append('font_file', snapshot.fontFile);
  body.append('background_image', snapshot.background ?? '');
  const channels = snapshot.ink.match(/[\da-f]{2}/gi)?.map((value) => Number.parseInt(value, 16));
  body.append('fill', `(${(channels ?? [0, 0, 0]).join(',')},255)`);
  body.append('preview', String(mode === 'preview'));
  body.append('pdf_save', String(mode === 'pdf'));
  body.append('full_preview', String(mode === 'preview' && snapshot.fullPreview));
  body.append('isUnderlined', String(snapshot.underlined));
  body.append('enableEnglishSpacing', String(snapshot.englishSpacing));
  return body;
}
export async function createGeneration(
  snapshot: GenerationSnapshot,
  mode: GenerationMode,
  signal?: AbortSignal,
): Promise<string> {
  const response = await fetchApi('/api/generate_handwriting', {
    method: 'POST',
    body: generationFormData(snapshot, mode),
    signal: signal ?? null,
  });
  return parsePayload(
    v.object({ task_id: v.pipe(v.string(), v.nonEmpty()) }),
    await readJson(response),
  ).task_id;
}
export function parseTask(value: unknown, expectedId: string): GenerationTask {
  const task = parsePayload(taskSchema, value);
  if (task.task_id !== undefined && task.task_id !== expectedId)
    throw new ApiError('invalidResponse');
  return task;
}
export async function getGenerationTask(id: string, signal?: AbortSignal): Promise<GenerationTask> {
  return parseTask(
    await readJson(
      await fetchApi(`/api/generate_handwriting/task/${encodeURIComponent(id)}`, {
        signal: signal ?? null,
      }),
    ),
    id,
  );
}
export function isTerminalTask(task: GenerationTask): boolean {
  return task.task_status === 'completed' || task.task_status === 'failed';
}
export async function getGenerationResult(
  id: string,
  mode: GenerationMode,
  signal?: AbortSignal,
): Promise<GenerationResult> {
  const response = await fetchApi(
    `/api/generate_handwriting/task/${encodeURIComponent(id)}/result`,
    { signal: signal ?? null },
  );
  const type = response.headers.get('content-type') ?? '';
  if (mode === 'preview') {
    if (type.includes('json')) {
      const value = parsePayload(
        v.object({ images: v.array(v.string()) }),
        await readJson(response),
      );
      return {
        type: 'images',
        images: value.images.map((image) => `data:image/png;base64,${image}`),
      };
    }
    if (type.startsWith('image/')) return { type: 'image', blob: await response.blob() };
  } else if (
    (mode === 'pdf' && type.includes('application/pdf')) ||
    (mode === 'zip' && /application\/(?:zip|x-zip-compressed)/.test(type))
  ) {
    return { type: 'download', mode, blob: await response.blob() };
  }
  throw new ApiError('invalidResponse');
}
export const taskQueryOptions = (id: string, operationSignal?: AbortSignal) =>
  queryOptions({
    queryKey: generationKeys.task(id),
    queryFn: ({ signal }) =>
      getGenerationTask(id, operationSignal ? AbortSignal.any([signal, operationSignal]) : signal),
    retry: false,
    networkMode: 'always',
    staleTime: 0,
  });
export const resultQueryOptions = (
  id: string,
  mode: GenerationMode,
  operationSignal?: AbortSignal,
) =>
  queryOptions({
    queryKey: generationKeys.result(id, mode),
    queryFn: ({ signal }) =>
      getGenerationResult(
        id,
        mode,
        operationSignal ? AbortSignal.any([signal, operationSignal]) : signal,
      ),
    retry: false,
    networkMode: 'always',
    staleTime: Infinity,
  });
