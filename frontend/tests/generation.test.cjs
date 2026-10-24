const assert = require('node:assert/strict');
const { test } = require('node:test');

async function modules() {
  const [query, generation, session, client, catalog] = await Promise.all([
    import('@tanstack/react-query'),
    import('../src/api/generation.ts'),
    import('../src/features/generation/taskSession.ts'),
    import('../src/api/client.ts'),
    import('../src/api/catalog.ts'),
  ]);
  return { ...query, ...generation, ...session, ...client, ...catalog };
}

function browser(t, script) {
  const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', {
    value: { location: { href: 'https://handwriting.test/editor' } },
    configurable: true,
  });
  t.after(() => {
    if (originalWindow) Object.defineProperty(globalThis, 'window', originalWindow);
    else delete globalThis.window;
  });
  const sockets = [];
  class Socket {
    onopen = null;
    onmessage = null;
    onerror = null;
    onclose = null;
    closed = false;
    constructor(address) {
      this.address = String(address);
      sockets.push(this);
      queueMicrotask(() => script(this));
    }
    close() {
      this.closed = true;
    }
    message(payload) {
      this.onmessage?.({ data: JSON.stringify(payload) });
    }
  }
  t.mock.property(globalThis, 'WebSocket', Socket);
  return sockets;
}

async function setup(t, script) {
  const api = await modules();
  const client = new api.QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: Infinity } },
  });
  t.after(() => client.clear());
  return { ...api, client, sockets: browser(t, script) };
}

test('a completed socket updates the shared task cache and never polls', async (t) => {
  const api = await setup(t, (socket) => {
    socket.onopen?.();
    socket.message({ task_id: 'job', task_status: 'processing', task_progress: 42 });
    assert.equal(api.client.getQueryData(api.generationKeys.task('job')).task_progress, 42);
    socket.message({ task_id: 'job', task_status: 'completed', task_progress: 100 });
  });
  const request = t.mock.method(globalThis, 'fetch', () => {
    throw new Error('Unexpected polling');
  });
  const result = await api.observeGenerationTask(api.client, 'job', new AbortController().signal);
  assert.equal(result.task_status, 'completed');
  assert.equal(request.mock.callCount(), 0);
  assert.equal(api.sockets[0].address, 'wss://handwriting.test/api/generate_handwriting/ws/job');
  assert.equal(api.sockets[0].closed, true);
  assert.equal(api.sockets[0].onmessage, null);
});

test('disconnect polls through the same query cache and stops at completion', async (t) => {
  const api = await setup(t, (socket) => socket.onclose?.());
  const request = t.mock.method(globalThis, 'fetch', async (address) => {
    assert.equal(address, '/api/generate_handwriting/task/job');
    return Response.json({ task_id: 'job', task_status: 'completed', task_progress: 100 });
  });
  const result = await api.observeGenerationTask(api.client, 'job', new AbortController().signal);
  assert.equal(result, api.client.getQueryData(api.generationKeys.task('job')));
  assert.equal(request.mock.callCount(), 1);
});

test('a mismatched socket frame cannot overwrite another task and falls back to HTTP', async (t) => {
  const api = await setup(t, (socket) => {
    socket.message({ task_id: 'wrong-job', task_status: 'completed' });
  });
  t.mock.method(globalThis, 'fetch', async () =>
    Response.json({ task_id: 'job', task_status: 'completed' }),
  );
  await api.observeGenerationTask(api.client, 'job', new AbortController().signal);
  assert.equal(api.client.getQueryData(api.generationKeys.task('wrong-job')), undefined);
  assert.equal(api.client.getQueryData(api.generationKeys.task('job')).task_id, 'job');
});

test('task failure preserves its diagnostic message and does not fetch a result', async (t) => {
  const api = await setup(t, (socket) =>
    socket.message({ task_status: 'failed', error_message: 'Font is unavailable' }),
  );
  const request = t.mock.method(globalThis, 'fetch', () => {
    throw new Error('Unexpected request');
  });
  await assert.rejects(api.observeGenerationTask(api.client, 'job', new AbortController().signal), {
    code: 'taskFailed',
    serverMessage: 'Font is unavailable',
  });
  assert.equal(request.mock.callCount(), 0);
});

test('aborting a socket closes it and discards late frames without starting polling', async (t) => {
  const controller = new AbortController();
  const api = await setup(t, (socket) => {
    const lateFrame = socket.onmessage;
    controller.abort();
    lateFrame?.({ data: JSON.stringify({ task_status: 'completed' }) });
  });
  const request = t.mock.method(globalThis, 'fetch', () => {
    throw new Error('Unexpected polling');
  });
  await assert.rejects(api.observeGenerationTask(api.client, 'job', controller.signal), {
    code: 'cancelled',
  });
  assert.equal(api.sockets[0].closed, true);
  assert.equal(api.client.getQueryData(api.generationKeys.task('job')), undefined);
  assert.equal(request.mock.callCount(), 0);
});

test('aborting HTTP polling cancels its transport and schedules no subsequent poll', async (t) => {
  const controller = new AbortController();
  const api = await setup(t, (socket) => socket.onerror?.());
  let transportAborted = false;
  const request = t.mock.method(
    globalThis,
    'fetch',
    (_address, options) =>
      new Promise((_resolve, reject) => {
        options.signal.addEventListener(
          'abort',
          () => {
            transportAborted = true;
            reject(new DOMException('Aborted', 'AbortError'));
          },
          { once: true },
        );
        queueMicrotask(() => controller.abort());
      }),
  );
  await assert.rejects(api.observeGenerationTask(api.client, 'job', controller.signal), {
    code: 'cancelled',
  });
  assert.equal(transportAborted, true);
  assert.equal(request.mock.callCount(), 1);
});

test('catalog queries deduplicate concurrent consumers and reuse cached values', async (t) => {
  const api = await modules();
  const client = new api.QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: Infinity } },
  });
  t.after(() => client.clear());
  const request = t.mock.method(globalThis, 'fetch', async () =>
    Response.json(['Font A', '字体 B']),
  );
  const [first, second] = await Promise.all([
    client.fetchQuery(api.fontsQueryOptions()),
    client.fetchQuery(api.fontsQueryOptions()),
  ]);
  assert.deepEqual(first, ['Font A', '字体 B']);
  assert.equal(first, second);
  assert.equal(await client.fetchQuery(api.fontsQueryOptions()), first);
  assert.equal(request.mock.callCount(), 1);
});

test('queue errors expose a retry deadline without retrying a POST', async (t) => {
  const api = await modules();
  const request = t.mock.method(globalThis, 'fetch', async () =>
    Response.json({ status: 'queue_full', estimated_wait_seconds: 2 }, { status: 429 }),
  );
  const before = Date.now();
  await assert.rejects(api.fetchApi('/api/generate_handwriting', { method: 'POST' }), (error) => {
    assert.equal(error.code, 'queueFull');
    assert.ok(error.retryUntil >= before + 2000);
    return true;
  });
  assert.equal(request.mock.callCount(), 1);
});

test('an aborted response retains the operation timeout classification', async () => {
  const api = await modules();
  const controller = new AbortController();
  controller.abort(new DOMException('Timed out', 'TimeoutError'));
  assert.equal(
    api.normalizeApiError(new api.ApiError('cancelled'), controller.signal).code,
    'timeout',
  );
});

test('FormData expands illustrations, binds the selected upload, and lets backgrounds determine page size', async () => {
  const api = await modules();
  const fontFile = new File(['font'], 'custom.ttf');
  const body = api.generationFormData(
    {
      text: '正文 ![插图 1|50%]',
      imageStore: { img_1: 'data:image/png;base64,YQ==' },
      numbers: { width: 100, height: 200, font_size: 20 },
      selectedFont: 'custom.ttf',
      fontFile,
      background: new File(['background'], 'paper.png'),
      underlined: true,
      englishSpacing: false,
      fullPreview: true,
      ink: '#12ABEF',
    },
    'preview',
  );
  assert.equal(body.has('width'), false);
  assert.equal(body.has('height'), false);
  assert.equal(body.get('font_size'), '20');
  assert.match(body.get('text'), /!\[插图 1\|50%\]\(data:image\/png;base64,YQ==\)/);
  assert.equal(body.get('font_file').name, 'custom.ttf');
  assert.equal(body.get('fill'), '(18,171,239,255)');
  assert.equal(body.get('full_preview'), 'true');
  assert.equal(body.get('isUnderlined'), 'true');
  assert.equal(body.get('enableEnglishSpacing'), 'false');
});

test('malformed task and result responses cannot become successful UI state', async (t) => {
  const api = await modules();
  assert.throws(() => api.parseTask({ task_status: 'completed', task_progress: 101 }, 'job'), {
    code: 'invalidResponse',
  });
  t.mock.method(
    globalThis,
    'fetch',
    async () => new Response('<html>Error</html>', { headers: { 'content-type': 'text/html' } }),
  );
  await assert.rejects(api.getGenerationResult('job', 'preview'), { code: 'invalidResponse' });
});

test('POST snapshots release uploaded files and illustration data on success, failure, and abort', async (t) => {
  const { createTask } = await import('../src/features/generation/createTask.ts');
  let fail = false;
  const transport = t.mock.method(globalThis, 'fetch', async () => {
    if (fail) throw new TypeError('Connection lost');
    return Response.json({ task_id: 'job' });
  });
  const request = () => ({
    payload: {
      text: 'illustration',
      imageStore: { img_1: 'data:image/png;base64,YQ==' },
      numbers: {},
      selectedFont: 'font.ttf',
      fontFile: new File(['font'], 'font.ttf'),
      background: new File(['image'], 'background.png'),
      underlined: false,
      englishSpacing: false,
      fullPreview: false,
      ink: '#000000',
    },
    mode: 'preview',
    controller: new AbortController(),
  });
  const succeeded = request();
  assert.equal(await createTask(succeeded), 'job');
  assert.equal(succeeded.payload, null);
  fail = true;
  const failed = request();
  await assert.rejects(createTask(failed), { code: 'networkError' });
  assert.equal(failed.payload, null);
  const aborted = request();
  aborted.controller.abort();
  await assert.rejects(createTask(aborted), { name: 'AbortError' });
  assert.equal(aborted.payload, null);
  assert.equal(transport.mock.callCount(), 2);
});

test('server cancellation is confirmed only after a terminal task, with escaped task IDs', async (t) => {
  const api = await modules();
  const { GenerationCancellation } = await import('../src/features/generation/cancellation.ts');
  const client = new api.QueryClient();
  t.after(() => client.clear());
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls.push([url, options.method]);
    return Response.json({task_id:'job /x', task_status: calls.length === 1 ? 'cancelling' : 'cancelled'});
  });
  const updates = [];
  const cancel = new GenerationCancellation(client, new AbortController().signal, (...args) => updates.push(args));
  const stop = cancel.request();
  assert.equal(cancel.observation.signal.aborted, true);
  assert.equal(calls.length, 0, 'must wait for POST create to return an id');
  cancel.created('job /x');
  await stop;
  await assert.rejects(cancel.wait(), {code:'cancelled'});
  assert.deepEqual(calls, [['/api/generate_handwriting/task/job%20%2Fx/cancel','POST'],['/api/generate_handwriting/task/job%20%2Fx',undefined]]);
  assert.equal(client.getQueryData(api.generationKeys.task('job /x')).task_status,'cancelled');
});

test('failed cancellation retains the barrier, retry confirms completed races without fetching a result', async (t) => {
  const api = await modules();
  const { GenerationCancellation } = await import('../src/features/generation/cancellation.ts');
  const client = new api.QueryClient();
  t.after(() => client.clear());
  let attempts = 0;
  t.mock.method(globalThis, 'fetch', async (url) => {
    assert.match(url, /\/cancel$/);
    if (++attempts === 1) throw new TypeError('offline');
    return Response.json({task_status:'completed'});
  });
  const updates=[];
  const cancel=new GenerationCancellation(client,new AbortController().signal,(...args)=>updates.push(args));
  cancel.created('job');
  await assert.rejects(cancel.request(),{code:'networkError'});
  let finished=false;
  const waiting=cancel.wait().catch(error=> {finished=true;assert.equal(error.code,'cancelled');});
  await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(finished,false);
  assert.equal(updates.at(-1)[0],false);
  await cancel.request();
  await waiting;
  assert.equal(attempts,2);
});

test('cancelled socket task is terminal and never downloads a result', async (t) => {
  const api = await setup(t, socket=>socket.message({task_status:'cancelled'}));
  t.mock.method(globalThis,'fetch',()=> {throw new Error('Unexpected fetch');});
  await assert.rejects(api.observeGenerationTask(api.client,'job',new AbortController().signal),{code:'cancelled'});
  assert.equal(api.sockets[0].closed,true);
});


for (const code of ['networkError', 'timeout']) {
  test(`automatic stop retains original ${code} after failed cancellation and manual retry`, async (t) => {
    const api = await modules();
    const { GenerationCancellation, GenerationStoppedError } = await import('../src/features/generation/cancellation.ts');
    const client = new api.QueryClient();
    t.after(() => client.clear());
    let attempts = 0;
    t.mock.method(globalThis, 'fetch', async () => {
      if (++attempts === 1) throw new TypeError('cancel endpoint offline');
      return Response.json({ task_status: 'cancelled' });
    });
    const cancellation = new GenerationCancellation(client, new AbortController().signal, () => {});
    cancellation.created('job');
    const reason = new api.ApiError(code, { status: 503, serverMessage: 'original failure' });
    await assert.rejects(cancellation.request(reason), { code: 'networkError' });
    await cancellation.request();
    for (const wait of [() => cancellation.wait(), () => cancellation.confirmedStop()]) {
      await assert.rejects(wait(), error => {
        assert.ok(error instanceof GenerationStoppedError);
        assert.equal(error.code, code);
        assert.equal(error.status, 503);
        assert.equal(error.serverMessage, 'original failure');
        assert.equal(error.cause, reason);
        return true;
      });
    }
  });
}
