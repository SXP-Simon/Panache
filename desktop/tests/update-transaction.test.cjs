const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const { Writable } = require('node:stream');
const { prepareTransaction, acknowledgeHealth, transactionArgument, hashFile, atomicRecord, cleanupTransactions } = require('../update-transaction');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'panache-transaction-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const directory = path.join(root, '中文 空格', 'HandwritingWeb');
  await fs.mkdir(directory, { recursive: true });
  const target = path.join(root, 'Panache.exe'), helper = path.join(root, 'fake-helper.exe'), file = path.join(root, 'download.exe');
  await fs.writeFile(target, 'old version'); await fs.writeFile(helper, 'fake helper, never executed'); await fs.writeFile(file, 'new version');
  const hash = await hashFile(file);
  return { directory, helper, target, parentExecutable: target, parentPid: 101, backendPid: 102, launcherPid: 103, platform: 'win32', artifact: { file, ...hash, current: '1.7.0', version: '1.7.1', portable: true }, signal: new AbortController().signal };
}
function fakeHelper(_executable, args, options) {
  const work = path.dirname(args[1]);
  assert.equal(options.windowsHide, true); assert.equal(options.detached, true);
  const child = new EventEmitter();
  child.pid = 500; child.exitCode = null; child.signalCode = null; child.killed = false; child.unref = () => {};
  child.stdin = new Writable({ write(chunk, _encoding, done) {
    const phase = String(chunk).startsWith('ARM ') ? 'armed' : 'aborted';
    atomicRecord(path.join(work, 'state.json'), { phase }).then(() => done(), done);
  } });
  void atomicRecord(path.join(work, 'state.json'), { phase: 'ready' });
  return child;
}
test('private plan uses exact names, Unicode paths, ARM handshake and abort without executing bytes', async (t) => {
  const options = await fixture(t);
  const transaction = await prepareTransaction({ ...options, spawnHelper: fakeHelper });
  const plan = JSON.parse(await fs.readFile(path.join(transaction.work, 'plan.json'), 'utf8'));
  assert.equal(plan.mode, 'win-portable'); assert.equal(plan.target, await fs.realpath(options.target));
  assert.equal(path.basename(plan.packageFile), 'package.exe'); assert.equal(plan.packageDigest, options.artifact.digest);
  assert.equal(transaction.armed, false); await transaction.arm(); assert.equal(transaction.armed, true);
  await transaction.abort();
  assert.equal(JSON.parse(await fs.readFile(path.join(transaction.work, 'state.json'))).phase, 'aborted');
  assert.equal(await fs.readFile(options.target, 'utf8'), 'old version');
});
test('copied package tampering and missing helper fail before parent exits', async (t) => {
  const options = await fixture(t);
  await fs.writeFile(options.artifact.file, 'tampered');
  await assert.rejects(prepareTransaction({ ...options, spawnHelper: () => assert.fail('must not spawn') }), /integrity/);
  await fs.writeFile(options.artifact.file, 'new version');
  await fs.rm(options.helper);
  await assert.rejects(prepareTransaction(options), /helperUnavailable/);
});
test('helper spawn errors fail promptly rather than waiting for preparation timeout', async (t) => {
  const options = await fixture(t);
  const start = Date.now();
  await assert.rejects(prepareTransaction({ ...options, spawnHelper: () => {
    const child = new EventEmitter(); child.pid = undefined; child.exitCode = null;
    child.stdin = new Writable({ write(_chunk, _encoding, done) { done(); } });
    queueMicrotask(() => child.emit('error', new Error('EACCES'))); return child;
  } }), /helperUnavailable/);
  assert.ok(Date.now() - start < 3000);
});
test('health acknowledgement binds nonce/version/executable and active health phase', async (t) => {
  const options = await fixture(t);
  const transaction = await prepareTransaction({ ...options, spawnHelper: fakeHelper });
  const nonce = path.basename(transaction.work);
  const ack = { directory: options.directory, argv: [`--panache-update=${nonce}`], version: '1.7.1', executable: options.target, pid: 104, backendPid: 105 };
  assert.equal(await acknowledgeHealth(ack), false);
  await atomicRecord(path.join(transaction.work, 'state.json'), { phase: 'awaiting_health' });
  assert.equal(await acknowledgeHealth({ ...ack, version: '1.7.0' }), false);
  assert.equal(await acknowledgeHealth({ ...ack, executable: options.helper }), false);
  assert.equal(await acknowledgeHealth(ack), true);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(transaction.work, 'health.json'))), { nonce, version: '1.7.1', pid: 104, backendPid: 105 });
  await transaction.abort();
});
test('fixed transaction argument rejects arbitrary paths and commands', () => {
  assert.equal(transactionArgument(['--panache-update=../../plan.json']), null);
  assert.equal(transactionArgument(['--panache-update=' + 'a'.repeat(32)]).nonce, 'a'.repeat(32));
  assert.equal(transactionArgument(['--panache-rollback=' + 'b'.repeat(32)]).rollback, true);
});
test('atomic health writes recover from leftover temporary file', async (t) => {
  const options = await fixture(t);
  const file = path.join(options.directory, 'health.json');
  await fs.writeFile(file + '.tmp', 'interrupted');
  await atomicRecord(file, { nonce: 'first' }); await atomicRecord(file, { nonce: 'second' });
  assert.equal(JSON.parse(await fs.readFile(file)).nonce, 'second');
});

test('cleanup preserves active recovery and unrelated paths while removing old terminal transactions', async (t) => {
  const options = await fixture(t);
  const root = path.join(options.directory, 'updates', 'transactions');
  for (const [id, phase] of [['a', 'committed'], ['b', 'failed'], ['c', 'awaiting_health']]) {
    const work = path.join(root, id.repeat(32)); await fs.mkdir(work, { recursive: true });
    await atomicRecord(path.join(work, 'state.json'), { phase, time: Date.now() / 1000 - 10 * 86400 });
  }
  await fs.mkdir(path.join(root, 'user-data'));
  await cleanupTransactions(options.directory);
  assert.deepEqual((await fs.readdir(root)).sort(), ['b'.repeat(32), 'c'.repeat(32), 'user-data'].sort());
});
