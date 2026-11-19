import { queryOptions } from '@tanstack/react-query';
import * as v from 'valibot';
import { expandInlineImages } from '../utils/inlineImageManager.ts';
import { ApiError, fetchApi, parsePayload, readJson } from './client.ts';
import type { GenerationMode, GenerationResult, GenerationSnapshot } from './types.ts';
import { finePreviewSchema } from '../features/preview/fineEditModel.ts';

const nullableCount = v.optional(v.nullable(v.pipe(v.number(), v.finite(), v.minValue(0))));
export const taskSchema = v.object({
  task_id: v.optional(v.string()),
  task_status: v.picklist([
    'pending',
    'processing',
    'completed',
    'failed',
    'cancelling',
    'cancelled',
  ]),
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
function inkFill(color: string) {
  const channels = color.match(/[\da-f]{2}/gi)?.map((value) => Number.parseInt(value, 16));
  return `(${(channels ?? [0, 0, 0]).join(',')},255)`;
}
export function generationFormData(snapshot: GenerationSnapshot, mode: GenerationMode): FormData {
  const body = new FormData();
  body.append('text', expandInlineImages(snapshot.text, snapshot.imageStore));
  for (const [key, value] of Object.entries(snapshot.numbers)) {
    if (snapshot.background && (key === 'width' || key === 'height')) continue;
    body.append(key, String(value));
  }
  body.append('font_option', snapshot.selectedFont);
  if (snapshot.selectedLatinFont) body.append('latin_font_option', snapshot.selectedLatinFont);
  if (snapshot.digitFont === 'latin') body.append('digit_font', 'latin');
  if (snapshot.fontFile?.name === snapshot.selectedFont)
    body.append('font_file', snapshot.fontFile);
  body.append('background_image', snapshot.background ?? '');
  body.append('fill', inkFill(snapshot.ink));
  if (snapshot.separateLatinInk) {
    body.append('separate_latin_ink', 'true');
    body.append('latin_fill', inkFill(snapshot.latinInk ?? snapshot.ink));
  }
  body.append('preview', String(mode === 'preview'));
  body.append('ink_layers', 'true');
  if (snapshot.fineEdit) {
    body.append('fine_edit', 'true');
    if (snapshot.fineEdits?.text === snapshot.text && mode !== 'preview') {
      const { key, glyphs } = snapshot.fineEdits;
      const data = JSON.stringify({ key, glyphs });
      if (data.length > 1_000_000)
        body.append(
          'fine_edits_file',
          new Blob([data], { type: 'application/json' }),
          'fine-edits.json',
        );
      else body.append('fine_edits', data);
    }
  }
  body.append('pdf_save', String(mode === 'pdf'));
  body.append('full_preview', String(mode === 'preview' && snapshot.fullPreview));
  body.append('isUnderlined', String(snapshot.underlined));
  if (!snapshot.background && snapshot.paperPattern)
    body.append('paper_pattern', snapshot.paperPattern);
  body.append('layout_style', snapshot.layoutStyle ?? 'standard');
  if (snapshot.firstLineIndent) body.append('first_line_indent', 'true');
  if (snapshot.monospaced) body.append('monospaced', 'true');
  body.append('background_ruled', String(Boolean(snapshot.background && snapshot.backgroundRuled)));
  body.append('enableEnglishSpacing', String(snapshot.englishSpacing));
  return body;
}
export async function createGeneration(
  snapshot: GenerationSnapshot,
  mode: GenerationMode,
  signal?: AbortSignal,
  taskId?: string,
): Promise<string> {
  const response = await fetchApi('/api/generate_handwriting', {
    method: 'POST',
    ...(taskId ? { headers: { 'X-Panache-Task-Id': taskId } } : {}),
    body: generationFormData(snapshot, mode),
    signal: signal ?? null,
  });
  return parsePayload(
    v.object({ task_id: v.pipe(v.string(), v.nonEmpty()) }),
    await readJson(response),
  ).task_id;
}
/** Older servers may ignore the client ID header; only advertise early cancellation when proven. */
export async function supportsTaskIdentity(signal: AbortSignal): Promise<boolean> {
  try {
    const data = parsePayload(
      v.object({
        capabilities: v.optional(v.object({ task_submission_id: v.optional(v.boolean()) })),
      }),
      await readJson(await fetchApi('/api/version', { signal })),
    );
    return data.capabilities?.task_submission_id === true;
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return false;
    throw error;
  }
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
export async function cancelGenerationTask(
  id: string,
  signal?: AbortSignal,
): Promise<GenerationTask> {
  return parseTask(
    await readJson(
      await fetchApi(`/api/generate_handwriting/task/${encodeURIComponent(id)}/cancel`, {
        method: 'POST',
        signal: signal ?? null,
      }),
    ),
    id,
  );
}
export function isTerminalTask(task: GenerationTask): boolean {
  return ['completed', 'failed', 'cancelled'].includes(task.task_status);
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
        v.object({
          images: v.array(v.string()),
          ink_layers: v.optional(v.array(v.string())),
          latin_ink_layers: v.optional(v.array(v.nullable(v.string()))),
          fine_edit: v.optional(finePreviewSchema),
        }),
        await readJson(response),
      );
      if (
        (value.ink_layers && value.ink_layers.length !== value.images.length) ||
        (value.latin_ink_layers && value.latin_ink_layers.length !== value.images.length) ||
        (value.fine_edit && value.fine_edit.pages.length !== value.images.length)
      )
        throw new ApiError('invalidResponse');
      return {
        type: 'images',
        images: value.images.map((image) => `data:image/png;base64,${image}`),
        ...(value.fine_edit ? { fineEdit: value.fine_edit } : {}),
        ...(value.ink_layers
          ? { inkLayers: value.ink_layers.map((image) => `data:image/png;base64,${image}`) }
          : {}),
        ...(value.latin_ink_layers
          ? {
              latinInkLayers: value.latin_ink_layers.map((image) =>
                image === null ? null : `data:image/png;base64,${image}`,
              ),
            }
          : {}),
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
