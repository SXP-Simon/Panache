import type { QueryClient } from '@tanstack/react-query';
import { ApiError, normalizeApiError } from '../../api/client.ts';
import {
  generationKeys,
  isTerminalTask,
  parseTask,
  taskQueryOptions,
} from '../../api/generation.ts';
import type { GenerationTask } from '../../api/generation.ts';

function terminal(task: GenerationTask): boolean {
  if (task.task_status === 'failed') {
    const message = task.error_message || task.task_message;
    throw new ApiError('taskFailed', message ? { serverMessage: message } : {});
  }
  return task.task_status === 'completed';
}

function delay(signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const abort = () => {
      clearTimeout(timer);
      signal.removeEventListener('abort', abort);
      reject(normalizeApiError(signal.reason, signal));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', abort);
      resolve();
    }, 1500);
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
  });
}

async function observeSocket(client: QueryClient, id: string, signal: AbortSignal): Promise<void> {
  signal.throwIfAborted();
  const address = new URL(
    `/api/generate_handwriting/ws/${encodeURIComponent(id)}`,
    window.location.href,
  );
  address.protocol = address.protocol === 'https:' ? 'wss:' : 'ws:';
  let socket: WebSocket;
  try {
    socket = new WebSocket(address);
  } catch {
    return;
  }
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    let silence: ReturnType<typeof setTimeout> | undefined;
    const finish = (cancelled = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(connecting);
      if (silence !== undefined) clearTimeout(silence);
      signal.removeEventListener('abort', abort);
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
      if (cancelled) reject(normalizeApiError(signal.reason, signal));
      else resolve();
    };
    const abort = () => finish(true);
    const connecting = setTimeout(() => finish(), 5000);
    const watchSilence = () => {
      if (silence !== undefined) clearTimeout(silence);
      silence = setTimeout(() => finish(), 15_000);
    };
    signal.addEventListener('abort', abort, { once: true });
    socket.onopen = () => {
      clearTimeout(connecting);
      watchSilence();
    };
    socket.onmessage = (event: MessageEvent<unknown>) => {
      if (settled || signal.aborted) return;
      try {
        if (typeof event.data !== 'string') throw new ApiError('invalidResponse');
        const source: unknown = JSON.parse(event.data);
        const task = parseTask(source, id);
        client.setQueryData(generationKeys.task(id), task);
        if (isTerminalTask(task)) finish();
        else watchSilence();
      } catch {
        finish();
      }
    };
    socket.onerror = () => finish();
    socket.onclose = () => finish();
    if (signal.aborted) abort();
  });
}

export async function observeGenerationTask(
  client: QueryClient,
  id: string,
  signal: AbortSignal,
): Promise<GenerationTask> {
  const existing = client.getQueryData<GenerationTask>(generationKeys.task(id));
  if (existing && terminal(existing)) return existing;
  await observeSocket(client, id, signal);
  signal.throwIfAborted();
  const pushed = client.getQueryData<GenerationTask>(generationKeys.task(id));
  if (pushed && terminal(pushed)) return pushed;
  while (!signal.aborted) {
    const task = await client.fetchQuery(taskQueryOptions(id, signal));
    signal.throwIfAborted();
    if (terminal(task)) return task;
    await delay(signal);
  }
  throw normalizeApiError(signal.reason, signal);
}
