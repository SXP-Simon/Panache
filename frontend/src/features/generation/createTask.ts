import { ApiError } from '../../api/client.ts';
import { createGeneration } from '../../api/generation.ts';
import type { GenerationMode, GenerationSnapshot } from '../../api/types.ts';

export interface GenerationRequest {
  payload: GenerationSnapshot | null;
  mode: GenerationMode;
  controller: AbortController;
}

export async function createTask(request: GenerationRequest): Promise<string> {
  try {
    request.controller.signal.throwIfAborted();
    if (!request.payload) throw new ApiError('invalidResponse');
    return await createGeneration(request.payload, request.mode, request.controller.signal);
  } finally {
    request.payload = null;
  }
}
