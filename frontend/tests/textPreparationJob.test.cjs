const { test } = require('node:test');
const assert = require('node:assert/strict');

function fakeWorker() {
  return {
    onmessage: null, onerror: null, onmessageerror: null,
    terminated: 0, requests: [],
    terminate() { this.terminated++; },
    postMessage(value) { this.requests.push(value); },
  };
}
const request = { source: '# title $x^2$', tableMode: 'latex' };

test('stopping terminates computation and late worker replies cannot settle the job', async () => {
  const { prepareTextInWorker } = await import('../src/utils/textPreparationJob.ts');
  const controller = new AbortController();
  const worker = fakeWorker();
  const result = prepareTextInWorker(request, controller.signal, () => worker);
  const lateReply = worker.onmessage;
  const rejected = assert.rejects(result, { name: 'AbortError' });
  controller.abort();
  lateReply({ data: { text: 'stale' } });
  await rejected;
  assert.equal(worker.terminated, 1);
  assert.equal(worker.onmessage, null);
  assert.equal(worker.onerror, null);
  assert.equal(worker.onmessageerror, null);
  assert.deepEqual(worker.requests, [request]);
});

test('a new run is independent, and successful completion releases its worker', async () => {
  const { prepareTextInWorker } = await import('../src/utils/textPreparationJob.ts');
  const old = fakeWorker(), next = fakeWorker();
  const stopped = new AbortController();
  const first = prepareTextInWorker(request, stopped.signal, () => old);
  const rejected = assert.rejects(first, { name: 'AbortError' });
  stopped.abort();
  await rejected;
  const controller = new AbortController();
  const second = prepareTextInWorker(request, controller.signal, () => next);
  next.onmessage({ data: { text: 'title x²' } });
  assert.equal(await second, 'title x²');
  controller.abort();
  assert.equal(next.terminated, 1);
});

test('pre-cancelled jobs do not construct a worker; startup and worker errors reject', async () => {
  const { prepareTextInWorker } = await import('../src/utils/textPreparationJob.ts');
  await assert.rejects(prepareTextInWorker(request, AbortSignal.abort(), () => {
    assert.fail('worker must not start');
  }), { name: 'AbortError' });
  for (const event of ['onerror', 'onmessageerror']) {
    const worker = fakeWorker();
    const result = prepareTextInWorker(request, new AbortController().signal, () => worker);
    worker[event]({});
    await assert.rejects(result);
    assert.equal(worker.terminated, 1);
  }
  const worker = fakeWorker();
  worker.postMessage = () => { throw new Error('clone failed'); };
  await assert.rejects(prepareTextInWorker(request, new AbortController().signal, () => worker));
  assert.equal(worker.terminated, 1);
});
