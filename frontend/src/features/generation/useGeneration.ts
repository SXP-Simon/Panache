import { useCallback, useEffect, useRef } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { ApiError, normalizeApiError } from '../../api/client.ts';
import { generationKeys, resultQueryOptions } from '../../api/generation.ts';
import type { GenerationMode, GenerationResult, GenerationSnapshot } from '../../api/types.ts';
import { observeGenerationTask } from './taskSession.ts';
import { readGenerationState } from './state.ts';
import type { ActiveGeneration } from './state.ts';
import { createTask } from './createTask.ts';

export { useGenerationState } from './state.ts';
export type { GenerationState } from './state.ts';
export interface GenerateOptions {
  onCreated?: (id: string) => Promise<void>;
}
interface OperationBase {
  mode: GenerationMode;
  controller: AbortController;
  token: number;
}
interface CompletedOperation {
  taskId: string;
  mode: GenerationMode;
}
type Operation = OperationBase &
  (
    | {
        type: 'create';
        payload: GenerationSnapshot | null;
        onCreated: GenerateOptions['onCreated'] | null;
      }
    | { type: 'resume'; taskId: string }
  );
let nextToken = 0;

export function useGeneration() {
  const client = useQueryClient();
  const current = useRef<OperationBase | null>(null);
  const { mutateAsync } = useMutation<CompletedOperation, ApiError, Operation>({
    mutationKey: generationKeys.mutation,
    retry: false,
    networkMode: 'always',
    mutationFn: async (operation) => {
      const { controller, token, mode } = operation;
      const timer = setTimeout(
        () => controller.abort(new DOMException('Generation timed out', 'TimeoutError')),
        300_000,
      );
      try {
        const taskId = operation.type === 'create' ? await createTask(operation) : operation.taskId;
        controller.signal.throwIfAborted();
        if (current.current?.token === token)
          client.setQueryData<ActiveGeneration>(generationKeys.active, { taskId, mode, token });
        if (operation.type === 'create') {
          try {
            await operation.onCreated?.(taskId);
          } finally {
            operation.onCreated = null;
          }
        }
        controller.signal.throwIfAborted();
        await observeGenerationTask(client, taskId, controller.signal);
        controller.signal.throwIfAborted();
        await client.fetchQuery(resultQueryOptions(taskId, mode, controller.signal));
        controller.signal.throwIfAborted();
        return { taskId, mode };
      } catch (cause) {
        throw normalizeApiError(cause, controller.signal);
      } finally {
        if (operation.type === 'create') {
          operation.payload = null;
          operation.onCreated = null;
        }
        clearTimeout(timer);
        if (current.current?.token === token) current.current = null;
      }
    },
  });
  const cancel = useCallback(() => {
    const operation = current.current;
    if (!operation) return;
    operation.controller.abort();
    const active = client.getQueryData<ActiveGeneration>(generationKeys.active);
    if (active?.token === operation.token && active.taskId) {
      void client.cancelQueries({ queryKey: generationKeys.task(active.taskId), exact: true });
      void client.cancelQueries({
        queryKey: generationKeys.result(active.taskId, active.mode),
        exact: true,
      });
    }
    current.current = null;
  }, [client]);
  useEffect(() => {
    window.addEventListener('pagehide', cancel);
    return () => {
      window.removeEventListener('pagehide', cancel);
      cancel();
    };
  }, [cancel]);

  const start = useCallback(
    async (operation: Operation): Promise<GenerationResult> => {
      cancel();
      current.current = operation;
      client.setQueryData<ActiveGeneration>(generationKeys.active, {
        taskId: operation.type === 'resume' ? operation.taskId : null,
        mode: operation.mode,
        token: operation.token,
      });
      try {
        const completed = await mutateAsync(operation);
        operation.controller.signal.throwIfAborted();
        const result = client.getQueryData<GenerationResult>(
          generationKeys.result(completed.taskId, completed.mode),
        );
        if (!result) throw new ApiError('invalidResponse');
        return result;
      } finally {
        if (operation.type === 'create') {
          operation.payload = null;
          operation.onCreated = null;
        }
      }
    },
    [cancel, client, mutateAsync],
  );
  const generate = useCallback(
    (snapshot: GenerationSnapshot, mode: GenerationMode, options: GenerateOptions = {}) => {
      const error = readGenerationState(client).error;
      if (error && error.retryUntil > Date.now()) return Promise.reject(error);
      return start({
        type: 'create',
        payload: snapshot,
        mode,
        onCreated: options.onCreated ?? null,
        controller: new AbortController(),
        token: ++nextToken,
      });
    },
    [client, start],
  );
  const resume = useCallback(
    (taskId: string, mode: GenerationMode) => {
      return start({
        type: 'resume',
        taskId,
        mode,
        controller: new AbortController(),
        token: ++nextToken,
      });
    },
    [start],
  );
  return { generate, resume, cancel };
}
