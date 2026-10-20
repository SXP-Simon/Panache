const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomBytes, createHash } = require('node:crypto');

async function readState(work) {
  try {
    const file = path.join(work, 'state.json');
    if ((await fs.stat(file)).size > 262144) throw new Error('helperFailed');
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function hashFile(file) {
  const details = await fs.lstat(file);
  if (!details.isFile() || details.isSymbolicLink()) throw new Error('integrity');
  const hash = createHash('sha256');
  const input = await fs.open(file, 'r');
  try { for await (const chunk of input.createReadStream({ autoClose: false })) hash.update(chunk); }
  finally { await input.close(); }
  return { size: details.size, digest: hash.digest('hex') };
}
async function waitPhase(work, child, accepted, signal, timeout = 180000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (signal?.aborted) throw new Error('cancelled');
    const state = await readState(work);
    if (accepted.includes(state?.phase)) return state;
    if (['failed', 'aborted'].includes(state?.phase)) throw new Error(state.reason || 'helperFailed');
    if (!child.pid) throw new Error('helperUnavailable');
    if (child.exitCode !== null || child.signalCode) throw new Error('helperFailed');
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('helperTimeout');
}
async function atomicRecord(file, value) {
  const temporary = `${file}.${randomBytes(8).toString('hex')}.tmp`;
  try {
    const output = await fs.open(temporary, 'wx', 0o600);
    try { await output.writeFile(JSON.stringify(value), 'utf8'); await output.sync(); }
    finally { await output.close(); }
    await fs.rename(temporary, file);
  } finally { await fs.rm(temporary, { force: true }).catch(() => {}); }
}

async function prepareTransaction({ directory, helper, target, parentExecutable, parentPid, backendPid, launcherPid = null, platform, artifact, rollback, signal, spawnHelper = spawn }) {
  if (!Number.isSafeInteger(parentPid) || parentPid <= 0 || !Number.isSafeInteger(backendPid) || backendPid <= 0) throw new Error('helperFailed');
  const dataRoot = await fs.realpath(directory);
  const parentExe = await fs.realpath(parentExecutable);
  const installedTarget = await fs.realpath(target);
  const nonce = randomBytes(16).toString('hex');
  const work = path.join(dataRoot, 'updates', 'transactions', nonce);
  await fs.mkdir(work, { recursive: true, mode: 0o700 });
  const mode = platform === 'darwin' ? 'mac-bundle' : artifact.portable ? 'win-portable' : 'win-install';
  let child;
  let armed = false;
  const abort = async () => {
    if (child && !child.killed) {
      if (!child.stdin.destroyed) { child.stdin.write('ABORT\n'); child.stdin.end(); }
      try { await waitPhase(work, child, ['aborted'], null, 15000); }
      catch { /* The current application remains running; recovery owns any prepared files. */ }
    }
  };
  try {
    const packageFile = path.join(work, platform === 'darwin' ? 'package.zip' : 'package.exe');
    await fs.copyFile(artifact.file, packageFile, 1);
    const copied = await hashFile(packageFile);
    if (copied.size !== artifact.size || copied.digest !== artifact.digest) throw new Error('integrity');
    let previous = null;
    if (mode === 'win-install') previous = await rollback(work, signal);
    const helperName = platform === 'win32' ? 'panache-updater.exe' : 'panache-updater';
    const executable = path.join(work, helperName);
    const helperDetails = await fs.lstat(helper);
    if (!helperDetails.isFile() || helperDetails.isSymbolicLink()) throw new Error('helperUnavailable');
    await fs.copyFile(helper, executable, 1);
    if (platform !== 'win32') await fs.chmod(executable, 0o700);
    const plan = {
      schema: 1, appId: 'io.github.sxp-simon.handwriting', nonce, mode,
      current: artifact.current, version: artifact.version, target: installedTarget, dataRoot,
      packageFile, packageSize: artifact.size, packageDigest: artifact.digest,
      rollbackFile: previous?.file ?? null, rollbackSize: previous?.size ?? null, rollbackDigest: previous?.digest ?? null,
      parentPid, backendPid, parentExecutable: parentExe, launcherPid,
    };
    await atomicRecord(path.join(work, 'plan.json'), plan);
    if (signal.aborted) throw new Error('cancelled');
    child = spawnHelper(executable, ['--plan', path.join(work, 'plan.json')], { cwd: work, detached: true, windowsHide: true, stdio: ['pipe', 'ignore', 'ignore'], env: { ...process.env, ELECTRON_RUN_AS_NODE: undefined } });
    let launchError;
    child.once('error', (error) => { launchError = error; });
    child.stdin.on('error', () => {});
    await waitPhase(work, child, ['ready'], signal);
    if (launchError) throw new Error('helperUnavailable');
    return {
      work,
      async arm() {
        if (signal.aborted || child.exitCode !== null) throw new Error('cancelled');
        child.stdin.write(`ARM ${nonce}\n`);
        await waitPhase(work, child, ['armed'], signal, 10000);
        armed = true;
        child.unref();
      },
      abort,
      get armed() { return armed; },
    };
  } catch (error) {
    await abort();
    if (!child) await fs.rm(work, { recursive: true, force: true });
    if (error.code === 'ENOENT') throw new Error('helperUnavailable');
    throw error;
  }
}

function transactionArgument(argv) {
  const match = argv.map((value) => /^--panache-(update|rollback)=([a-f0-9]{32})$/.exec(value)).find(Boolean);
  return match ? { rollback: match[1] === 'rollback', nonce: match[2] } : null;
}
async function acknowledgeHealth({ directory, argv, version, executable, portableExecutable, pid, backendPid }) {
  const pending = transactionArgument(argv);
  if (!pending) return false;
  const root = await fs.realpath(directory);
  const work = path.join(root, 'updates', 'transactions', pending.nonce);
  const planFile = path.join(work, 'plan.json');
  const details = await fs.lstat(planFile);
  if (details.isSymbolicLink() || !details.isFile() || details.size > 262144) return false;
  const plan = JSON.parse(await fs.readFile(planFile, 'utf8'));
  const expected = pending.rollback ? plan.current : plan.version;
  const actual = await fs.realpath(portableExecutable || executable);
  const target = plan.mode === 'win-portable' ? plan.target : plan.mode === 'mac-bundle' ? path.join(plan.target, 'Contents', 'MacOS', 'Panache') : path.join(plan.target, 'Panache.exe');
  const state = await readState(work);
  const phases = pending.rollback ? ['awaiting_rollback_health', 'rolling_back', 'awaiting_health', 'applying', 'swapped', 'armed', 'failed'] : ['awaiting_health'];
  if (!phases.includes(state?.phase) || plan.schema !== 1 || plan.appId !== 'io.github.sxp-simon.handwriting' || plan.nonce !== pending.nonce || plan.dataRoot !== root || expected !== version || await fs.realpath(target) !== actual || !Number.isSafeInteger(pid) || !Number.isSafeInteger(backendPid)) return false;
  await atomicRecord(path.join(work, 'health.json'), { nonce: pending.nonce, version, pid, backendPid });
  return true;
}
async function recoveryNotice(directory) {
  const root = path.join(directory, 'updates', 'transactions');
  let entries;
  try { entries = await fs.readdir(root, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  let newest = null;
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.isSymbolicLink() || !/^[a-f0-9]{32}$/.test(entry.name)) continue;
    const work = path.join(root, entry.name);
    const file = path.join(work, 'result.json');
    try {
      const details = await fs.lstat(file);
      if (details.isSymbolicLink() || details.size > 262144 || Date.now() - details.mtimeMs > 7 * 86400000) continue;
      const result = JSON.parse(await fs.readFile(file, 'utf8'));
      if (result.nonce !== entry.name || result.outcome !== 'rolled_back') continue;
      if (!newest || details.mtimeMs > newest.time) newest = { time: details.mtimeMs, reason: result.reason };
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return newest?.reason ?? null;
}
async function cleanupTransactions(directory, now = Date.now()) {
  let root;
  try { root = path.join(await fs.realpath(directory), 'updates', 'transactions'); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  let entries;
  try {
    const details = await fs.lstat(root);
    if (!details.isDirectory() || details.isSymbolicLink()) return;
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch (error) { if (error.code === 'ENOENT') return; throw error; }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.isSymbolicLink() || !/^[a-f0-9]{32}$/.test(entry.name)) continue;
    const work = path.join(root, entry.name);
    const state = await readState(work).catch(() => null);
    if (['committed', 'rolled_back', 'aborted'].includes(state?.phase) && Number.isFinite(state.time) && now / 1000 - state.time > 7 * 86400)
      await fs.rm(work, { recursive: true, force: true });
  }
}
module.exports = { prepareTransaction, acknowledgeHealth, recoveryNotice, transactionArgument, hashFile, atomicRecord, waitPhase, cleanupTransactions };
