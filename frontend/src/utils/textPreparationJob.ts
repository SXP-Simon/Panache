import type { TableMode } from './cleanMarkdown.ts';

export interface PreparationRequest {
  source: string;
  tableMode: TableMode;
}
export type PreparationReply = { text: string } | { error: string };
type PreparationWorker = Pick<
  Worker,
  'onmessage' | 'onerror' | 'onmessageerror' | 'postMessage' | 'terminate'
>;

/** Each run owns its worker so stopping releases CPU, not just the pending UI promise. */
export function prepareTextInWorker(
  request: PreparationRequest,
  signal: AbortSignal,
  createWorker: () => PreparationWorker = () =>
    new Worker(new URL('../workers/prepare-text.ts', import.meta.url), { type: 'module' }),
): Promise<string> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    const worker = createWorker();
    let settled = false;
    const finish = (reply: PreparationReply) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener('abort', abort);
      worker.onmessage = null;
      worker.onerror = null;
      worker.onmessageerror = null;
      worker.terminate();
      if (signal.aborted) reject(signal.reason);
      else if ('error' in reply) reject(new Error(reply.error));
      else resolve(reply.text);
    };
    const abort = () => finish({ error: 'Text preparation cancelled' });
    worker.onmessage = (event: MessageEvent<PreparationReply>) => finish(event.data);
    worker.onerror = () => finish({ error: 'Text preparation worker failed' });
    worker.onmessageerror = () => finish({ error: 'Invalid text preparation response' });
    signal.addEventListener('abort', abort, { once: true });
    try {
      worker.postMessage(request);
    } catch {
      finish({ error: 'Unable to start text preparation' });
    }
  });
}
