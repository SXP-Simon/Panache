import { useCallback, useEffect, useRef } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { ApiError, normalizeApiError } from '../../api/client.ts';
import {
  generationKeys,
  isTerminalTask,
  resultQueryOptions,
  supportsTaskIdentity,
} from '../../api/generation.ts';
import type { GenerationTask } from '../../api/generation.ts';
import type { GenerationMode, GenerationResult, GenerationSnapshot } from '../../api/types.ts';
import { observeGenerationTask } from './taskSession.ts';
import { readGenerationState } from './state.ts';
import type { ActiveGeneration } from './state.ts';
import { GenerationCancellation } from './cancellation.ts';
import { createTask } from './createTask.ts';

export { useGenerationState } from './state.ts';
export type { GenerationState } from './state.ts';
export interface GenerateOptions {
  onCreated?: (id: string) => Promise<void>;
  onStopping?: (id: string) => Promise<void>;
}
interface OperationBase {
  mode: GenerationMode;
  controller: AbortController;
  token: number;
  cancellation: GenerationCancellation;
}
interface CompletedOperation {
  taskId: string;
  mode: GenerationMode;
}
type Operation = OperationBase &
  (
    | {
        type: 'create';
        taskId: string;
        payload: GenerationSnapshot | null;
        onCreated: GenerateOptions['onCreated'] | null;
      }
    | { type: 'resume'; taskId: string; stopping: boolean }
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
      const { controller, token, mode, cancellation } = operation;
      // The deadline stops transport, while the lifetime remains usable to stop the renderer.
      const deadline = new AbortController();
      const workSignal = AbortSignal.any([controller.signal, deadline.signal]);
      const observationSignal = AbortSignal.any([workSignal, cancellation.observation.signal]);
      const timer = setTimeout(() => {
        if (!cancellation.requested)
          deadline.abort(new DOMException('Generation timed out', 'TimeoutError'));
      }, 300_000);
      let submitted = operation.type === 'resume';
      let attempted = submitted;
      let identityKnown = submitted;
      try {
        if (operation.type === 'create') {
          const clientIdentity = await supportsTaskIdentity(
            AbortSignal.any([
              workSignal,
              cancellation.observation.signal,
              AbortSignal.timeout(5000),
            ]),
          );
          if (clientIdentity) {
            await operation.onCreated?.(operation.taskId);
            cancellation.created(operation.taskId);
            identityKnown = true;
          } else if (cancellation.requested) {
            // No request was sent yet, so there is no renderer to stop.
            cancellation.created(null);
          }
          await cancellation.wait();
          attempted = true;
          const requestedId = operation.taskId;
          const creating = createTask(operation, workSignal).then(async (id) => {
            operation.taskId = id;
            identityKnown = true;
            if (!controller.signal.aborted && (!clientIdentity || id !== requestedId))
              await operation.onCreated?.(id);
            operation.onCreated = null;
            // Publish identity only after its record; onStopping must write last.
            cancellation.created(id);
            return id;
          });
          await Promise.race([creating, cancellation.confirmedStop()]);
        } else {
          cancellation.created(operation.taskId);
        }
        submitted = true;
        const taskId = operation.taskId;
        if (current.current?.token === token)
          client.setQueryData<ActiveGeneration>(generationKeys.active, (previous) => ({
            ...previous,
            taskId,
            mode,
            token,
          }));
        await cancellation.wait();
        workSignal.throwIfAborted();
        await observeGenerationTask(client, taskId, observationSignal);
        workSignal.throwIfAborted();
        await client.fetchQuery(resultQueryOptions(taskId, mode, observationSignal));
        workSignal.throwIfAborted();
        await cancellation.wait();
        return { taskId, mode };
      } catch (cause) {
        const error = normalizeApiError(cause, workSignal);
        const rejected =
          !submitted &&
          error instanceof ApiError &&
          (error.code === 'queueFull' ||
            (error.status !== undefined &&
              error.status >= 400 &&
              error.status < 500 &&
              error.status !== 408));
        if (!identityKnown) {
          if (!attempted || rejected) cancellation.created(null);
          else cancellation.creationFailed(error);
        }
        const task = client.getQueryData<GenerationTask>(generationKeys.task(operation.taskId));
        // A missing task observed after submission is distinct from an absent cancel endpoint.
        const missingTask = submitted && (error.status === 404 || error.status === 410);
        if (
          !controller.signal.aborted &&
          attempted &&
          !rejected &&
          !missingTask &&
          !(task && isTerminalTask(task)) &&
          !cancellation.requested
        ) {
          // Failed observation/upload does not prove that the backend has stopped.
          // Retain the lock and retry controls until cancellation is confirmed.
          void cancellation.request(error).catch(() => {
            /* Keep the retry action available. */
          });
        }
        await cancellation.wait();
        throw error;
      } finally {
        if (operation.type === 'create') {
          operation.payload = null;
          operation.onCreated = null;
        }
        clearTimeout(timer);
        if (cancellation.requested) controller.abort();
        if (current.current?.token === token) current.current = null;
      }
    },
  });
  const detach = useCallback(() => {
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
    window.addEventListener('pagehide', detach);
    return () => {
      window.removeEventListener('pagehide', detach);
      detach();
    };
  }, [detach]);

  const start = useCallback(
    async (operation: Operation): Promise<GenerationResult> => {
      if (current.current) throw new ApiError('invalidResponse');
      current.current = operation;
      client.setQueryData<ActiveGeneration>(generationKeys.active, {
        taskId: operation.taskId,
        mode: operation.mode,
        token: operation.token,
      });
      if (operation.type === 'resume' && operation.stopping) {
        void operation.cancellation.request().catch(() => {
          /* Shared state exposes retry. */
        });
      }
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
    [client, mutateAsync],
  );
  const cancel = useCallback(
    () => current.current?.cancellation.request() ?? Promise.resolve(),
    [],
  );
  const controls = useCallback(
    (beforeStop?: GenerateOptions['onStopping']) => {
      const controller = new AbortController();
      const token = ++nextToken;
      const cancellation = new GenerationCancellation(
        client,
        controller.signal,
        (pending, error) => {
          client.setQueryData<ActiveGeneration>(generationKeys.active, (previous) =>
            previous?.token === token
              ? { ...previous, cancelling: true, cancelPending: pending, cancelError: error }
              : previous,
          );
        },
      );
      cancellation.beforeStop = beforeStop;
      return { controller, token, cancellation };
    },
    [client],
  );
  const generate = useCallback(
    (snapshot: GenerationSnapshot, mode: GenerationMode, options: GenerateOptions = {}) => {
      const error = readGenerationState(client).error;
      if (error && error.retryUntil > Date.now()) return Promise.reject(error);
      return start({
        type: 'create',
        taskId: crypto.randomUUID(),
        payload: snapshot,
        mode,
        onCreated: options.onCreated ?? null,
        ...controls(options.onStopping),
      });
    },
    [client, start, controls],
  );
  const resume = useCallback(
    (
      taskId: string,
      mode: GenerationMode,
      stopping = false,
      onStopping?: GenerateOptions['onStopping'],
    ) => {
      return start({
        type: 'resume',
        taskId,
        stopping,
        mode,
        ...controls(onStopping),
      });
    },
    [start, controls],
  );
  return { generate, resume, cancel };
}
