const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { setupPersistence } = require('../studio-storage');

async function fixture(t) {
  const prefix = 'hww-studio-storage-test-';
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), prefix));
  t.after(async () => {
    const absolute = path.resolve(directory);
    assert.ok(absolute.startsWith(`${path.resolve(os.tmpdir())}${path.sep}`));
    assert.ok(path.basename(absolute).startsWith(prefix));
    await fs.rm(absolute, { recursive: true, force: true });
  });
  const handlers = new Map();
  const frame = { url: 'http://127.0.0.1:5005/' };
  const contents = { mainFrame: frame, getURL: () => frame.url };
  const window = { webContents: contents, isDestroyed: () => false };
  const storage = setupPersistence({
    ipcMain: { handle: (channel, handler) => handlers.set(channel, handler) },
    getWindow: () => window,
    getAllowedOrigin: () => 'http://127.0.0.1:5005',
    dataDir: () => directory,
  });
  const invoke = (channel, ...args) => {
    const handler = handlers.get(channel);
    assert.ok(handler, `Missing IPC handler: ${channel}`);
    return handler({ sender: contents, senderFrame: frame }, ...args);
  };
  const record = (key) => path.join(directory, 'studio', 'records', `${key}.json`);
  return { storage, invoke, record };
}

test('same-key writes remain FIFO and reads wait for every previously accepted write', async (t) => {
  const { invoke } = await fixture(t);
  const key = 'studio.workspace';
  await invoke('storage:write-record', key, 'previous committed value');
  const values = ['first'.repeat(100_000), 'second'.repeat(200_000), '最后一次修改'];
  const pending = values.map((value) => invoke('storage:write-record', key, value));
  const read = invoke('storage:read-record', key);
  assert.equal(await read, values.at(-1));
  await Promise.all(pending);
});

test('atomic replacement preserves exact UTF-8 JSON and removes temporary files', async (t) => {
  const { invoke, record } = await fixture(t);
  const key = 'studio.workspace';
  await invoke('storage:write-record', key, JSON.stringify({ text: '旧内容' }));
  const value = JSON.stringify({ text: '中文 English\n数学 √(x²+1) 🖋️', theme: 'dark' });
  await invoke('storage:write-record', key, value);
  const bytes = await fs.readFile(record(key));
  assert.equal(bytes.toString('utf8'), value);
  assert.equal(bytes.byteLength, Buffer.byteLength(value, 'utf8'));
  assert.deepEqual(JSON.parse(bytes.toString('utf8')), JSON.parse(value));
  assert.deepEqual(await fs.readdir(path.dirname(record(key))), [`${key}.json`]);
});

test('drain waits for accepted IO, is idempotent while pending and permits a cancelled quit retry', async (t) => {
  const { storage, invoke, record } = await fixture(t);
  const key = 'studio.workspace';
  const value = JSON.stringify({ text: '关窗前最后的几个字 XYZ987' });
  const write = invoke('storage:write-record', key, value);
  const draining = storage.drain();
  assert.equal(storage.drain(), draining);
  let settled = false;
  void draining.then(() => { settled = true; });
  await Promise.resolve();
  assert.equal(settled, false, 'An accepted write has not completed its filesystem IO yet');
  await Promise.all([write, draining]);
  assert.equal(await fs.readFile(record(key), 'utf8'), value);
  await invoke('storage:write-record', key, 'cancelled quit: editing continues');
  await storage.drain();
  assert.equal(await fs.readFile(record(key), 'utf8'), 'cancelled quit: editing continues');
});


test('Panache preserves packaged Chromium storage and lock identity, development remains unchanged', async (t) => {
  const { configureAppIdentity } = require('../app-identity');
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'panache-identity-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const calls = [];
  configureAppIdentity({ isPackaged: true, commandLine: { hasSwitch: () => false }, getPath: (name) => { assert.equal(name, 'appData'); return directory; }, setPath: (...args) => calls.push(args) });
  const expected = path.join(directory, 'HandwritingWeb');
  assert.deepEqual(calls, [['userData', expected], ['sessionData', expected]]);
  assert.equal((await fs.stat(expected)).isDirectory(), true);
  configureAppIdentity({ isPackaged: true, commandLine: { hasSwitch: (name) => { assert.equal(name, 'user-data-dir'); return true; } }, getPath: () => { throw new Error('must preserve explicit profile'); } });
  configureAppIdentity({ isPackaged: false, getPath: () => { throw new Error('must preserve development identity'); } });
});
