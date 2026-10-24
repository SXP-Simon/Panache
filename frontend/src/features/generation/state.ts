import { useCallback, useMemo, useSyncExternalStore } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import type { QueryClient } from '@tanstack/react-query';
import { ApiError } from '../../api/client.ts';
import { generationKeys } from '../../api/generation.ts';
import type { GenerationTask } from '../../api/generation.ts';
import type { GenerationMode, GenerationResult } from '../../api/types.ts';

export interface ActiveGeneration {
  taskId: string | null;
  mode: GenerationMode;
  token: number;
  cancelling?: boolean;
  cancelPending?: boolean;
  cancelError?: ApiError | null;
}
export interface GenerationState {
  taskId: string | null;
  mode: GenerationMode;
  busy: boolean;
  cancelling: boolean;
  cancelPending: boolean;
  cancelError: ApiError | null;
  progress: number;
  task: GenerationTask | null;
  error: ApiError | null;
  retryUntil: number;
  retrySeconds: number;
  result: GenerationResult | null;
}
const snapshots = new WeakMap<QueryClient, GenerationState>();
interface Subscription {
  listeners: Set<() => void>;
  unsubscribeQueries: () => void;
  unsubscribeMutations: () => void;
  timer: ReturnType<typeof setInterval> | null;
}
const subscriptions = new WeakMap<QueryClient, Subscription>();

export function readGenerationState(client: QueryClient): GenerationState {
  const active = client.getQueryData<ActiveGeneration>(generationKeys.active);
  const mutation = client
    .getMutationCache()
    .findAll({ mutationKey: generationKeys.mutation, exact: true })
    .at(-1);
  const failure = mutation?.state.error;
  const error = failure instanceof ApiError && failure.code !== 'cancelled' ? failure : null;
  const retryUntil = error?.retryUntil ?? 0;
  const taskId = active?.taskId ?? null;
  const mode = active?.mode ?? 'preview';
  const task = taskId
    ? (client.getQueryData<GenerationTask>(generationKeys.task(taskId)) ?? null)
    : null;
  const result = taskId
    ? (client.getQueryData<GenerationResult>(generationKeys.result(taskId, mode)) ?? null)
    : null;
  const state: GenerationState = {
    taskId,
    mode,
    busy: mutation?.state.status === 'pending',
    cancelling: mutation?.state.status === 'pending' && Boolean(active?.cancelling),
    cancelPending: Boolean(active?.cancelPending),
    cancelError: active?.cancelError ?? null,
    progress: task?.task_progress ?? 0,
    task,
    error,
    retryUntil,
    retrySeconds: Math.max(0, Math.ceil((retryUntil - Date.now()) / 1000)),
    result,
  };
  const previous = snapshots.get(client);
  if (
    previous &&
    previous.taskId === state.taskId &&
    previous.mode === state.mode &&
    previous.busy === state.busy &&
    previous.cancelling === state.cancelling &&
    previous.cancelPending === state.cancelPending &&
    previous.cancelError === state.cancelError &&
    previous.task === state.task &&
    previous.error === state.error &&
    previous.retrySeconds === state.retrySeconds &&
    previous.retryUntil === state.retryUntil &&
    previous.result === state.result
  )
    return previous;
  snapshots.set(client, state);
  return state;
}

function subscribe(client: QueryClient, listener: () => void): () => void {
  let subscription = subscriptions.get(client);
  if (!subscription) {
    const listeners = new Set<() => void>();
    const emit = () => {
      const current = subscriptions.get(client);
      if (!current) return;
      const state = readGenerationState(client);
      if (state.retrySeconds > 0 && current.timer === null) current.timer = setInterval(emit, 1000);
      if (state.retrySeconds === 0 && current.timer !== null) {
        clearInterval(current.timer);
        current.timer = null;
      }
      for (const notify of listeners) notify();
    };
    subscription = {
      listeners,
      unsubscribeQueries: client.getQueryCache().subscribe(emit),
      unsubscribeMutations: client.getMutationCache().subscribe(emit),
      timer: null,
    };
    subscriptions.set(client, subscription);
  }
  subscription.listeners.add(listener);
  if (readGenerationState(client).retrySeconds > 0 && subscription.timer === null) {
    subscription.timer = setInterval(() => {
      const current = subscriptions.get(client);
      if (!current) return;
      if (readGenerationState(client).retrySeconds === 0 && current.timer !== null) {
        clearInterval(current.timer);
        current.timer = null;
      }
      for (const notify of current.listeners) notify();
    }, 1000);
  }
  return () => {
    const current = subscriptions.get(client);
    if (!current) return;
    current.listeners.delete(listener);
    if (!current.listeners.size) {
      current.unsubscribeQueries();
      current.unsubscribeMutations();
      if (current.timer !== null) clearInterval(current.timer);
      subscriptions.delete(client);
    }
  };
}

export function useGenerationState(): GenerationState;
export function useGenerationState<Selected>(
  selector: (state: GenerationState) => Selected,
): Selected;
export function useGenerationState<Selected>(
  selector?: (state: GenerationState) => Selected,
): GenerationState | Selected {
  const client = useQueryClient();
  const subscribeToState = useCallback(
    (listener: () => void) => subscribe(client, listener),
    [client],
  );
  const getSnapshot = useMemo(() => selectedSnapshot(client, selector), [client, selector]);
  return useSyncExternalStore(subscribeToState, getSnapshot, getSnapshot);
}

function selectedSnapshot<Selected>(
  client: QueryClient,
  selector?: (state: GenerationState) => Selected,
) {
  let previous: GenerationState | null = null;
  let selected: GenerationState | Selected = readGenerationState(client);
  return () => {
    const state = readGenerationState(client);
    if (previous !== state) {
      previous = state;
      selected = selector ? selector(state) : state;
    }
    return selected;
  };
}
