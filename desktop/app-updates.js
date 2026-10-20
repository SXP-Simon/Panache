const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');

const API = 'https://api.github.com/repos/SXP-Simon/Panache/releases/latest';
const RELEASES = 'https://github.com/SXP-Simon/Panache/releases';
const MAX_BYTES = 2 * 1024 * 1024 * 1024;
function stableVersion(value) {
  if (typeof value !== 'string') return null;
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(value ?? '');
  return match ? match.slice(1).map(BigInt) : null;
}
function newerVersion(latest, current) {
  const a = stableVersion(latest), b = stableVersion(current);
  if (!a || !b) return null;
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}
function assetName(version, platform, arch, portable) {
  if (!stableVersion(version)) return null;
  if (platform === 'win32' && arch === 'x64') return `Panache-${portable ? 'portable' : 'Setup'}-${version}.exe`;
  if (platform === 'darwin' && arch === 'arm64') return `Panache-${version}-arm64.zip`;
  return null;
}
function trustedUrl(value, download = false) {
  const url = new URL(value);
  const allowed = download ? ['github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'] : ['api.github.com'];
  if (url.protocol !== 'https:' || url.username || url.password || url.port || !allowed.includes(url.hostname)) throw new Error('unsafe');
  return url;
}
async function fetchTrusted(fetcher, url, signal, download = false) {
  for (let count = 0; count < 6; count++) {
    trustedUrl(url, download);
    const response = await fetcher(url, { signal, redirect: 'manual', headers: { 'User-Agent': 'Panache-update', Accept: 'application/vnd.github+json' } });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location) throw new Error('unsafe');
      url = new URL(location, url).href;
      continue;
    }
    if (response.status === 403 || response.status === 429) throw new Error('rateLimited');
    if (!response.ok) throw new Error(response.status === 404 ? 'pending' : 'network');
    return response;
  }
  throw new Error('unsafe');
}
async function boundedJson(response) {
  const reader = response.body?.getReader();
  if (!reader) throw new Error('invalid');
  let size = 0;
  const chunks = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 1024 * 1024) throw new Error('invalid');
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { await reader.cancel().catch(() => {}); }
}
function releaseAsset(release, current, platform, arch, portable) {
  if (!release || typeof release !== 'object') throw new Error('invalid');
  const changed = newerVersion(release.tag_name, current);
  if (changed === null || release.draft || release.prerelease || !Array.isArray(release.assets)) throw new Error('invalid');
  const version = release.tag_name.replace(/^v/, '');
  const base = { version, current, notes: typeof release.body === 'string' ? release.body.slice(0, 50000) : '', releaseUrl: `${RELEASES}/tag/v${version}`, portable };
  if (!changed) return { ...base, status: 'current' };
  const name = assetName(version, platform, arch, portable);
  if (!name) return { ...base, status: 'unsupported' };
  const expectedUrl = `${RELEASES}/download/v${version}/${name}`;
  const assets = release.assets.filter((asset) => asset && typeof asset === 'object' && asset.name === name);
  const asset = assets.length === 1 ? assets[0] : null;
  if (!asset || asset.state !== 'uploaded' || !Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.size > MAX_BYTES || !/^sha256:[a-f0-9]{64}$/i.test(asset.digest ?? '') || asset.browser_download_url !== expectedUrl) return { ...base, status: 'pending' };
  return { ...base, status: 'available', asset: { name, size: asset.size, url: expectedUrl, digest: asset.digest.slice(7).toLowerCase() } };
}
async function cleanupStaleUpdates(directory, now = Date.now()) {
  const root = path.resolve(directory);
  let entries;
  try { entries = await fs.readdir(root, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.isSymbolicLink() || !/^update-[a-zA-Z0-9]{6}$/.test(entry.name)) continue;
    const target = path.resolve(root, entry.name);
    if (path.dirname(target) !== root) continue;
    const stat = await fs.lstat(target);
    if (!stat.isSymbolicLink() && stat.isDirectory() && now - stat.mtimeMs > 7 * 24 * 60 * 60 * 1000) await fs.rm(target, { recursive: true, force: true });
  }
}
async function downloadRollback({ fetcher, current, work, signal, files = fs }) {
  let release;
  try { release = await boundedJson(await fetchTrusted(fetcher, API.replace('/latest', `/tags/v${current}`), signal)); }
  catch (error) { if (error.message === 'pending') throw new Error('rollbackUnavailable'); throw error; }
  const selected = releaseAsset(release, '0.0.0', 'win32', 'x64', false);
  if (selected.version !== current || selected.status !== 'available') throw new Error('rollbackUnavailable');
  const asset = selected.asset;
  const file = path.join(work, 'rollback.exe');
  const output = await files.open(file, 'wx', 0o600);
  const hash = createHash('sha256');
  let size = 0;
  let reader;
  try {
    const response = await fetchTrusted(fetcher, asset.url, signal, true);
    reader = response.body?.getReader();
    if (!reader) throw new Error('integrity');
    while (true) {
      const chunk = await reader.read();
      if (signal.aborted) throw new Error('cancelled');
      if (chunk.done) break;
      size += chunk.value.length;
      if (size > asset.size) throw new Error('integrity');
      hash.update(chunk.value);
      await output.writeFile(chunk.value);
    }
    if (size !== asset.size || hash.digest('hex') !== asset.digest) throw new Error('integrity');
    await output.sync();
    return { file, size, digest: asset.digest };
  } finally { await reader?.cancel().catch(() => {}); await output.close(); }
}
function createUpdater({ current, platform, arch, portable, directory, notify = () => {}, fetcher = fetch, beforeOpen = async () => {}, openPath, reveal, files = fs, development = false, install, recovery = null }) {
  let state = { status: 'idle', current, portable, recovery };
  let selected = null;
  let operation = null;
  let ready = null;
  const emit = (patch) => { state = { ...state, ...patch }; const { asset, ...publicState } = state; notify(publicState); return publicState; };
  const cleanup = async () => {
    if (!ready) return;
    const target = ready.directory;
    ready = null;
    if (path.dirname(target) !== path.resolve(directory) || !path.basename(target).startsWith('update-')) throw new Error('unsafe');
    await files.rm(target, { recursive: true, force: true });
  };
  const failure = (error) => {
    const code = ({ permissions: 'permissionDenied', recoveryUnavailable: 'rollbackUnavailable', systemApproval: 'trustRequired', unsupportedInstall: 'unsupportedLocation', processIdentity: 'invalidInstallation', replaceFailed: 'fileLocked', stopFailed: 'helperFailed', exitTimeout: 'helperFailed' })[error.message] || error.message;
    return ['rateLimited', 'pending', 'invalid', 'unsafe', 'integrity', 'saveFailed', 'generationBusy', 'cleanupFailed', 'permissionDenied', 'helperUnavailable', 'helperFailed', 'helperTimeout', 'rollbackUnavailable', 'diskSpace', 'fileLocked', 'invalidBundle', 'invalidArchive', 'unsafePath', 'invalidInstallation', 'unsupportedLocation', 'trustRequired'].includes(code) ? code : 'network';
  };
  async function check() {
    if (development) return emit({ status: 'development' });
    if (operation) return emit({});
    operation = new AbortController();
    const timer = setTimeout(() => operation?.abort(), 20000);
    emit({ status: 'checking', error: undefined });
    try {
      const release = await boundedJson(await fetchTrusted(fetcher, API, operation.signal));
      const result = releaseAsset(release, current, platform, arch, portable);
      await cleanup();
      selected = result.asset ?? null;
      return emit({ ...result, bytes: 0, error: undefined, manualAvailable: false });
    } catch (error) { return emit({ status: 'error', error: failure(error) }); }
    finally { clearTimeout(timer); operation = null; }
  }
  async function download() {
    if (operation || !selected || !['available', 'cancelled', 'error'].includes(state.status)) return emit({});
    operation = new AbortController();
    const controller = operation;
    let temporary;
    let handle;
    const timer = setTimeout(() => controller.abort(), 30 * 60 * 1000);
    let idleTimer;
    const resetIdle = () => { clearTimeout(idleTimer); idleTimer = setTimeout(() => controller.abort(), 30000); };
    emit({ status: 'downloading', bytes: 0, total: selected.size, error: undefined, manualAvailable: false });
    try {
      await cleanup();
      await files.mkdir(directory, { recursive: true });
      temporary = await files.mkdtemp(path.join(path.resolve(directory), 'update-'));
      const target = path.join(temporary, selected.name);
      handle = await files.open(target, 'wx', 0o600);
      resetIdle();
      const response = await fetchTrusted(fetcher, selected.url, controller.signal, true);
      const declared = response.headers.get('content-length');
      if (declared && Number(declared) !== selected.size) throw new Error('integrity');
      const reader = response.body?.getReader();
      if (!reader) throw new Error('integrity');
      const hash = createHash('sha256');
      let bytes = 0;
      let lastProgress = 0;
      try {
        while (true) {
          const chunk = await reader.read();
          if (controller.signal.aborted) throw new Error('cancelled');
          if (chunk.done) break;
          resetIdle();
          bytes += chunk.value.length;
          if (bytes > selected.size || bytes > MAX_BYTES) throw new Error('integrity');
          hash.update(chunk.value);
          await handle.writeFile(chunk.value);
          if (Date.now() - lastProgress > 100 || bytes === selected.size) { emit({ bytes }); lastProgress = Date.now(); }
        }
      } finally { await reader.cancel().catch(() => {}); }
      if (bytes !== selected.size || hash.digest('hex') !== selected.digest) throw new Error('integrity');
      await handle.sync();
      await handle.close(); handle = null;
      if (controller.signal.aborted) throw new Error('cancelled');
      ready = { directory: temporary, file: target, digest: selected.digest, size: selected.size };
      temporary = null;
      return emit({ status: 'ready' });
    } catch (error) {
      return emit({ status: controller.signal.aborted ? 'cancelled' : 'error', error: controller.signal.aborted ? undefined : failure(error) });
    } finally {
      clearTimeout(timer); clearTimeout(idleTimer);
      await handle?.close().catch(() => {});
      try {
        if (temporary) await files.rm(temporary, { recursive: true, force: true });
      } catch { emit({ status: 'error', error: 'cleanupFailed' }); }
      finally { operation = null; }
    }
  }
  async function open(manual = false) {
    if (operation || !ready || !['ready', 'launched', 'error'].includes(state.status)) return emit({});
    operation = new AbortController();
    const controller = operation;
    const timer = setTimeout(() => controller.abort(), 10 * 60 * 1000);
    try {
      const hash = createHash('sha256');
      const handle = await files.open(ready.file, 'r');
      try { for await (const chunk of handle.createReadStream({ autoClose: false })) hash.update(chunk); }
      finally { await handle.close(); }
      if (hash.digest('hex') !== ready.digest) throw new Error('integrity');
      if (install && !manual) {
        emit({ status: 'preparing', error: undefined, manualAvailable: false });
        await install({ ...ready, current, version: state.version, portable }, controller.signal,
          (work, signal) => downloadRollback({ fetcher, current, work, signal, files }));
        return emit({ status: 'installing' });
      }
      await beforeOpen();
      if (portable || platform === 'darwin') reveal(ready.file);
      else if (await openPath(ready.file)) throw new Error('network');
      return emit({ status: portable ? 'ready' : 'launched' });
    } catch (error) {
      if (error.message === 'integrity') {
        try { await cleanup(); } catch { return emit({ status: 'error', error: 'cleanupFailed' }); }
      }
      return emit({ status: controller.signal.aborted || error.message === 'generationBusy' ? 'ready' : 'error', error: controller.signal.aborted ? undefined : failure(error), manualAvailable: !controller.signal.aborted && Boolean(ready) && !['integrity', 'generationBusy'].includes(error.message) });
    }
    finally { clearTimeout(timer); operation = null; }
  }
  return { check, download, open, manual: () => open(true), cancel: () => { if (['downloading', 'checking', 'preparing'].includes(state.status)) operation?.abort(); return emit({}); }, state: () => emit({}) };
}
function setupUpdater({ ipcMain, trustedRenderer, getWindow, ...options }) {
  const service = createUpdater({ ...options, notify: (state) => {
    const window = getWindow();
    if (window && !window.isDestroyed()) window.webContents.send('updates:state', state);
  } });
  for (const action of ['state', 'check', 'download', 'cancel', 'open', 'manual']) ipcMain.handle(`updates:${action}`, (event) => {
    if (!trustedRenderer(event)) throw new Error('Untrusted update request');
    return service[action]();
  });
  return service;
}
module.exports = { newerVersion, assetName, trustedUrl, releaseAsset, cleanupStaleUpdates, createUpdater, setupUpdater, downloadRollback };
