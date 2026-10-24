import type { QueryClient } from '@tanstack/react-query';
import { ApiError, normalizeApiError } from '../../api/client.ts';
import {
  cancelGenerationTask,
  generationKeys,
  getGenerationTask,
  isTerminalTask,
} from '../../api/generation.ts';

function deferred<Value>() {
  let resolve: (value: Value) => void = () => {};
  const promise = new Promise<Value>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
export class GenerationStoppedError extends ApiError {
  constructor(failure?: ApiError) {
    super(
      failure?.code ?? 'cancelled',
      failure
        ? {
            cause: failure,
            retryUntil: failure.retryUntil,
            ...(failure.status === undefined ? {} : { status: failure.status }),
            ...(failure.serverMessage === undefined
              ? {}
              : { serverMessage: failure.serverMessage }),
          }
        : {},
    );
  }
}

// Stopping observation is immediate; releasing the generation lock requires server confirmation.
export class GenerationCancellation {
  readonly observation = new AbortController();
  requested = false;
  private taskReady = deferred<void>();
  private taskId: string | null = null;
  private identityError: ApiError | null = null;
  private failure: ApiError | undefined;
  private stopped = deferred<void>();
  private pending: Promise<void> | null = null;
  beforeStop: ((id: string) => Promise<void>) | undefined;
  private client: QueryClient;
  private lifetime: AbortSignal;
  private update: (pending: boolean, error: ApiError | null) => void;
  constructor(
    client: QueryClient,
    lifetime: AbortSignal,
    update: (pending: boolean, error: ApiError | null) => void,
  ) {
    this.client = client;
    this.lifetime = lifetime;
    this.update = update;
  }
  created(id: string | null) {
    this.taskId = id;
    this.identityError = null;
    this.taskReady.resolve();
  }
  creationFailed(error: ApiError) {
    this.identityError = error;
    this.taskReady.resolve();
  }
  confirmedStop(): Promise<never> {
    return this.stopped.promise.then(() => {
      throw new GenerationStoppedError(this.failure);
    });
  }
  async wait(): Promise<void> {
    if (!this.requested) return;
    await new Promise<void>((resolve, reject) => {
      const abort = () => reject(normalizeApiError(this.lifetime.reason, this.lifetime));
      if (this.lifetime.aborted) {
        abort();
        return;
      }
      this.lifetime.addEventListener('abort', abort, { once: true });
      void this.stopped.promise.then(() => {
        this.lifetime.removeEventListener('abort', abort);
        resolve();
      });
    });
    throw new GenerationStoppedError(this.failure);
  }
  request(failure?: ApiError): Promise<void> {
    if (!this.requested) this.failure = failure;
    if (this.pending) return this.pending;
    this.requested = true;
    this.observation.abort();
    this.update(true, null);
    const attempt = async () => {
      try {
        await this.taskReady.promise;
        this.lifetime.throwIfAborted();
        if (this.identityError) throw this.identityError;
        let id = this.taskId;
        while (id) {
          await this.beforeStop?.(id);
          let task = await cancelGenerationTask(
            id,
            AbortSignal.any([this.lifetime, AbortSignal.timeout(15_000)]),
          );
          this.client.setQueryData(generationKeys.task(id), task);
          while (!isTerminalTask(task)) {
            await new Promise<void>((resolve, reject) => {
              const abort = () => {
                clearTimeout(timer);
                reject(normalizeApiError(this.lifetime.reason, this.lifetime));
              };
              const timer = setTimeout(() => {
                this.lifetime.removeEventListener('abort', abort);
                resolve();
              }, 400);
              this.lifetime.addEventListener('abort', abort, { once: true });
              if (this.lifetime.aborted) abort();
            });
            task = await getGenerationTask(
              id,
              AbortSignal.any([this.lifetime, AbortSignal.timeout(15_000)]),
            );
            this.client.setQueryData(generationKeys.task(id), task);
          }
          if (id === this.taskId) break;
          id = this.taskId;
        }
        this.stopped.resolve();
      } catch (cause) {
        const error = normalizeApiError(cause, this.lifetime);
        this.update(false, error);
        throw error;
      } finally {
        this.pending = null;
      }
    };
    this.pending = attempt();
    return this.pending;
  }
}
