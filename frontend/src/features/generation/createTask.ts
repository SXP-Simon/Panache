import { ApiError } from '../../api/client.ts';
import { createGeneration } from '../../api/generation.ts';
import type { GenerationMode, GenerationSnapshot } from '../../api/types.ts';

export interface GenerationRequest {
  payload: GenerationSnapshot | null;
  mode: GenerationMode;
  controller: AbortController;
  taskId?: string;
}

export async function createTask(
  request: GenerationRequest,
  signal = request.controller.signal,
): Promise<string> {
  try {
    signal.throwIfAborted();
    if (!request.payload) throw new ApiError('invalidResponse');
    return await createGeneration(
      request.payload,
      request.mode,
      AbortSignal.any([signal, AbortSignal.timeout(90_000)]),
      request.taskId,
    );
  } finally {
    request.payload = null;
  }
}
