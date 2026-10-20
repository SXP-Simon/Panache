const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { newerVersion, assetName, trustedUrl, releaseAsset, cleanupStaleUpdates, createUpdater, setupUpdater } = require('../app-updates');
const data = Buffer.from('verified installer bytes');
const digest = createHash('sha256').update(data).digest('hex');
function release(options = {}) {
  return { tag_name: 'v1.10.0', draft: false, prerelease: false, body: '# Changes\nTest', assets: [{ name: 'Panache-Setup-1.10.0.exe', size: data.length, digest: `sha256:${digest}`, state: 'uploaded', browser_download_url: 'https://github.com/SXP-Simon/Panache/releases/download/v1.10.0/Panache-Setup-1.10.0.exe' }], ...options };
}
async function fixture(t, fetcher, extra = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'panache-update-test-'));
  t.after(async () => { assert.equal(path.dirname(directory), os.tmpdir()); assert.ok(path.basename(directory).startsWith('panache-update-test-')); await fs.rm(directory, { recursive: true, force: true }); });
  const opened = [], revealed = [], events = [];
  const updater = createUpdater({ current: '1.6.0', platform: 'win32', arch: 'x64', portable: false, directory, fetcher: fetcher ?? (async (url) => new Response(url.includes('api.github.com') ? JSON.stringify(release()) : data)), openPath: async (file) => { opened.push(file); return ''; }, reveal: (file) => revealed.push(file), notify: (value) => events.push(value), ...extra });
  return { updater, directory, opened, revealed, events };
}
test('stable versions compare numerically and reject malformed, prerelease and unsafe versions', () => {
  assert.equal(newerVersion('v1.10.0', '1.9.99'), true);
  assert.equal(newerVersion('1.6.0', '1.6.0'), false);
  assert.equal(newerVersion('1.5.99', '1.6.0'), false);
  for (const value of ['1.2', '01.2.3', '1.2.3-beta', '1.2.3/evil', '1.2.3+dev']) assert.equal(newerVersion(value, '1.0.0'), null);
  assert.equal(assetName('1.10.0', 'win32', 'x64', true), 'Panache-portable-1.10.0.exe');
  assert.equal(assetName('1.10.0', 'darwin', 'arm64', false), 'Panache-1.10.0-arm64.dmg');
  for (const [platform, arch] of [['darwin', 'x64'], ['linux', 'x64'], ['win32', 'arm64']]) assert.equal(assetName('1.10.0', platform, arch, false), null);
});
test('release selection excludes Flutter and waits for uploaded hashed exact assets', () => {
  assert.equal(releaseAsset(release(), '1.6.0', 'win32', 'x64', false).status, 'available');
  assert.equal(releaseAsset(release(), '1.6.0', 'darwin', 'x64', false).status, 'unsupported');
  for (const change of [{ digest: null }, { size: 0 }, { state: 'new' }, { browser_download_url: 'https://example.com/file.exe' }, { name: 'Flutter-Panache-1.10.0-windows-x64.zip' }]) {
    const value = release(); Object.assign(value.assets[0], change);
    assert.equal(releaseAsset(value, '1.6.0', 'win32', 'x64', false).status, 'pending');
  }
  assert.throws(() => releaseAsset(release({ prerelease: true }), '1.6.0', 'win32', 'x64', false));
});
test('only HTTPS trusted API and GitHub storage hosts pass URL validation', () => {
  for (const value of ['http://github.com/a', 'https://github.com.evil.test/a', 'https://user:pass@github.com/a', 'https://github.com:444/a', 'file:///a', 'https://example.com/a']) assert.throws(() => trustedUrl(value, true));
  trustedUrl('https://release-assets.githubusercontent.com/file?token=test', true);
  assert.throws(() => trustedUrl('https://github.com/a'));
});
test('download is hash/size checked, exposes progress without paths and opens only on explicit action', async (t) => {
  const { updater, opened, events } = await fixture(t);
  await updater.check(); assert.equal(updater.state().status, 'available');
  await updater.download(); assert.equal(updater.state().status, 'ready'); assert.equal(opened.length, 0);
  assert.equal(events.some((event) => event.status === 'downloading' && event.bytes === data.length), true);
  assert.equal(JSON.stringify(events).includes('browser_download_url'), false);
  assert.equal('asset' in updater.state(), false);
  await updater.open(); assert.equal(opened.length, 1); assert.deepEqual(await fs.readFile(opened[0]), data);
});
test('portable update reveals the new binary without launching an installer', async (t) => {
  const info = release(); info.assets[0].name = 'Panache-portable-1.10.0.exe'; info.assets[0].browser_download_url = 'https://github.com/SXP-Simon/Panache/releases/download/v1.10.0/Panache-portable-1.10.0.exe';
  const { updater, opened, revealed } = await fixture(t, async (url) => new Response(url.includes('api.github.com') ? JSON.stringify(info) : data), { portable: true });
  await updater.check(); await updater.download(); await updater.open();
  assert.equal(opened.length, 0); assert.equal(revealed.length, 1);
});
test('corrupt and oversized downloads are removed and cannot be opened', async (t) => {
  for (const corrupted of [Buffer.alloc(data.length), Buffer.alloc(data.length + 1)]) {
    const { updater, directory, opened } = await fixture(t, async (url) => new Response(url.includes('api.github.com') ? JSON.stringify(release()) : corrupted));
    await updater.check(); await updater.download(); await updater.open();
    assert.equal(updater.state().error, 'integrity'); assert.deepEqual(await fs.readdir(directory), []); assert.equal(opened.length, 0);
  }
});
test('trusted download redirect is followed but untrusted redirect is rejected before fetch', async (t) => {
  const calls = [];
  const { updater, directory } = await fixture(t, async (url) => {
    calls.push(url);
    if (url.includes('api.github.com')) return new Response(JSON.stringify(release()));
    return new Response(null, { status: 302, headers: { location: 'https://evil.example/installer.exe' } });
  });
  await updater.check(); await updater.download();
  assert.equal(updater.state().error, 'unsafe'); assert.equal(calls.length, 2); assert.deepEqual(await fs.readdir(directory), []);
});
test('cancel aborts a download and removes partial files', async (t) => {
  let begin;
  const started = new Promise((resolve) => { begin = resolve; });
  const { updater, directory } = await fixture(t, async (url, { signal }) => {
    if (url.includes('api.github.com')) return new Response(JSON.stringify(release()));
    begin();
    return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  });
  await updater.check(); const pending = updater.download(); await started; updater.cancel(); await pending;
  assert.equal(updater.state().status, 'cancelled'); assert.deepEqual(await fs.readdir(directory), []);
});
test('failed saves and files modified after download never launch', async (t) => {
  const failed = await fixture(t, undefined, { beforeOpen: async () => { throw new Error('saveFailed'); } });
  await failed.updater.check(); await failed.updater.download(); await failed.updater.open();
  assert.equal(failed.updater.state().error, 'saveFailed'); assert.equal(failed.opened.length, 0);
  const changed = await fixture(t); await changed.updater.check(); await changed.updater.download();
  const dir = (await fs.readdir(changed.directory))[0]; await fs.writeFile(path.join(changed.directory, dir, 'Panache-Setup-1.10.0.exe'), 'tampered');
  await changed.updater.open(); assert.equal(changed.updater.state().error, 'integrity'); assert.equal(changed.opened.length, 0);
});
test('offline, rate limit and oversized metadata fail gracefully', async (t) => {
  for (const [fetcher, error] of [[async () => { throw new Error('offline'); }, 'network'], [async () => new Response('', { status: 403 }), 'rateLimited'], [async () => new Response('x'.repeat(1024 * 1024 + 1)), 'invalid']]) {
    const { updater } = await fixture(t, fetcher); await updater.check(); assert.equal(updater.state().error, error);
  }
});
test('update IPC rejects untrusted renderers and accepts no URL/path arguments', () => {
  const handlers = new Map();
  setupUpdater({ ipcMain: { handle: (channel, callback) => handlers.set(channel, callback) }, trustedRenderer: () => false, getWindow: () => null, current: '1.6.0', platform: 'win32', arch: 'x64', directory: '/unused' });
  for (const callback of handlers.values()) assert.throws(() => callback({}, 'https://evil.test/run.exe'), /Untrusted/);
  assert.equal(handlers.size, 5);
});
test('cancelling after all bytes arrive while file sync is pending never publishes ready', async (t) => {
  let unblock, syncing;
  const syncStarted = new Promise((resolve) => { syncing = resolve; });
  const gate = new Promise((resolve) => { unblock = resolve; });
  const files = { ...fs, open: async (...args) => {
    const handle = await fs.open(...args);
    if (args[1] === 'wx') { const original = handle.sync.bind(handle); handle.sync = async () => { syncing(); await gate; return original(); }; }
    return handle;
  } };
  const { updater, directory, events } = await fixture(t, undefined, { files });
  await updater.check(); const pending = updater.download(); await syncStarted; updater.cancel(); unblock(); await pending;
  assert.equal(updater.state().status, 'cancelled'); assert.equal(events.some((event) => event.status === 'ready'), false); assert.deepEqual(await fs.readdir(directory), []);
});
test('opening is exclusive with another open or check; reopening requires a separate action', async (t) => {
  let unblock, entered;
  const started = new Promise((resolve) => { entered = resolve; });
  const gate = new Promise((resolve) => { unblock = resolve; });
  const { updater, opened } = await fixture(t, undefined, { beforeOpen: async () => { entered(); await gate; } });
  await updater.check(); await updater.download();
  const pending = updater.open(); await started; await updater.open(); await updater.check(); unblock(); await pending;
  assert.equal(opened.length, 1); assert.equal(updater.state().status, 'launched');
  await updater.open(); assert.equal(opened.length, 2);
});

test('development never fetches or installs a packaged release', async (t) => { const { updater } = await fixture(t, async () => { throw new Error('must not fetch'); }, { development: true }); await updater.check(); assert.equal(updater.state().status, 'development'); });

test('failed removal never leaves the update service permanently locked', async (t) => {
  const { updater } = await fixture(t, async (url) => new Response(url.includes('api.github.com') ? JSON.stringify(release()) : 'bad'), { files: { ...fs, rm: async () => { throw new Error('EPERM'); } } });
  await updater.check(); await updater.download(); assert.equal(updater.state().error, 'cleanupFailed');
  await updater.check(); assert.equal(updater.state().status, 'available');
});
test('startup cache cleanup removes only old owned directories and preserves unrelated/recent files', async (t) => {
  const { directory } = await fixture(t);
  const old = path.join(directory, 'update-abc123'), recent = path.join(directory, 'update-def456'), other = path.join(directory, 'keep-my-files');
  for (const item of [old, recent, other]) await fs.mkdir(item);
  await fs.writeFile(path.join(old, 'package.exe'), 'stale');
  await fs.writeFile(path.join(directory, 'update-ghi789'), 'not a directory');
  const past = new Date(Date.now() - 8 * 86400000);
  await fs.utimes(old, past, past); await fs.utimes(other, past, past);
  await cleanupStaleUpdates(directory);
  assert.deepEqual((await fs.readdir(directory)).sort(), ['keep-my-files', 'update-def456', 'update-ghi789']);
});
