import * as v from 'valibot';

export type ApiErrorCode =
  | 'networkError'
  | 'invalidResponse'
  | 'taskFailed'
  | 'timeout'
  | 'cancelled'
  | 'backgroundDetectionFailed'
  | 'queueFull';
export class ApiError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number | undefined;
  readonly serverMessage: string | undefined;
  readonly retryUntil: number;
  constructor(
    code: ApiErrorCode,
    options: { status?: number; serverMessage?: string; retryUntil?: number; cause?: unknown } = {},
  ) {
    super(options.serverMessage ?? code, { cause: options.cause });
    this.name = 'ApiError';
    this.code = code;
    this.status = options.status;
    this.serverMessage = options.serverMessage;
    this.retryUntil = options.retryUntil ?? 0;
  }
}

const errorSchema = v.object({
  code: v.optional(v.string()),
  message: v.optional(v.string()),
  error: v.optional(v.string()),
  detail: v.optional(v.string()),
  status: v.optional(v.string()),
  estimated_wait_seconds: v.optional(v.pipe(v.number(), v.finite(), v.minValue(0))),
});

export function normalizeApiError(cause: unknown, signal?: AbortSignal): ApiError {
  if (signal?.aborted || (cause instanceof DOMException && cause.name === 'AbortError')) {
    const reason: unknown = signal?.reason;
    return new ApiError(
      reason instanceof DOMException && reason.name === 'TimeoutError' ? 'timeout' : 'cancelled',
      { cause },
    );
  }
  if (cause instanceof ApiError) return cause;
  return new ApiError('networkError', { cause });
}

export function parsePayload<Schema extends v.GenericSchema>(
  schema: Schema,
  source: unknown,
): v.InferOutput<Schema> {
  const parsed = v.safeParse(schema, source);
  if (!parsed.success) throw new ApiError('invalidResponse');
  return parsed.output;
}

export async function readJson(response: Response): Promise<unknown> {
  try {
    const value: unknown = await response.json();
    return value;
  } catch (cause) {
    if (cause instanceof DOMException && cause.name === 'AbortError')
      throw normalizeApiError(cause);
    throw new ApiError('invalidResponse', { cause });
  }
}

export async function fetchApi(path: string, options: RequestInit = {}): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(path, options);
  } catch (cause) {
    throw normalizeApiError(cause, options.signal ?? undefined);
  }
  if (response.ok) return response;
  const source: unknown = await response.json().catch(() => null);
  const parsed = v.safeParse(errorSchema, source);
  const message = parsed.success
    ? (parsed.output.message ?? parsed.output.error ?? parsed.output.detail)
    : undefined;
  const queued = parsed.success && parsed.output.status === 'queue_full';
  if (
    response.status === 422 &&
    parsed.success &&
    parsed.output.code === 'backgroundDetectionFailed'
  ) {
    throw new ApiError('backgroundDetectionFailed', { status: response.status });
  }
  throw new ApiError(queued ? 'queueFull' : 'networkError', {
    status: response.status,
    ...(message === undefined ? {} : { serverMessage: message }),
    ...(queued
      ? { retryUntil: Date.now() + Math.max(1, parsed.output.estimated_wait_seconds ?? 30) * 1000 }
      : {}),
  });
}
