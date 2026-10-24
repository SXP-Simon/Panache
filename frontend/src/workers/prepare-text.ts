import { prepareHandwritingText } from '../utils/prepareHandwritingText.ts';
import type { PreparationRequest, PreparationReply } from '../utils/textPreparationJob.ts';

// Only the worker message port is used; the parser also ships DOM rendering types.
declare const self: Pick<Worker, 'onmessage' | 'postMessage'>;
self.onmessage = (event: MessageEvent<PreparationRequest>) => {
  let reply: PreparationReply;
  try {
    reply = { text: prepareHandwritingText(event.data.source, event.data.tableMode) };
  } catch {
    reply = { error: 'Unable to prepare text' };
  }
  self.postMessage(reply);
};
