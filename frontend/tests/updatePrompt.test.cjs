const test = require('node:test');
const assert = require('node:assert/strict');
const storePromise = import('../src/features/updates/store.ts');
async function reset() { const { useUpdatesStore: store } = await storePromise; store.setState({ prompt: null, pendingPrompt: null, seen: [], update: { status: 'idle' } }); return store; }
test('manual prompt counts as reminded; automatic repeats stay silent and manual reopen remains possible', async () => {
  const store = await reset(); const update = { status: 'available', version: '1.7.0' }; store.getState().replace(update);
  store.getState().requestPrompt(update, 'release:1.7.0', true); store.getState().showPending();
  assert.equal(store.getState().prompt.update.version, '1.7.0');
  store.getState().dismissPrompt(); store.getState().requestPrompt(update, 'release:1.7.0');
  assert.equal(store.getState().pendingPrompt, null);
  store.getState().requestPrompt(update, 'release:1.7.0', true); store.getState().showPending();
  assert.equal(store.getState().prompt.update.version, '1.7.0');
});
test('queued prompts wait for the UI readiness signal and progress does not create another prompt', async () => {
  const store = await reset(); const update = { status: 'available', version: '1.7.0' }; store.getState().replace(update);
  store.getState().requestPrompt(update, 'release:1.7.0'); assert.equal(store.getState().prompt, null);
  store.getState().showPending(); store.getState().replace({ ...update, status: 'downloading' });
  assert.equal(store.getState().pendingPrompt, null); assert.equal(store.getState().prompt.key, 'release:1.7.0');
  store.getState().dismissPrompt(); store.getState().replace({ ...update, status: 'ready' });
  assert.equal(store.getState().prompt, null);
});
test('distinct waiting deployments can each notify once without a GitHub tag', async () => {
  const store = await reset(); const update = { status: 'available', deploymentId: 'deployment-1' };
  for (const key of ['deployment-1', 'deployment-2']) { store.getState().replace({ ...update, deploymentId: key }); store.getState().requestPrompt({ ...update, deploymentId: key }, key); store.getState().showPending(); assert.equal(store.getState().prompt.key, key); store.getState().dismissPrompt(); }
  store.getState().requestPrompt(update, 'deployment-1'); assert.equal(store.getState().pendingPrompt, null);
});

test('stale queued releases are discarded when a later check is current or fails', async () => {
  const store = await reset(); const update = { status: 'available', version: '1.7.0' };
  for (const status of ['current', 'error']) {
    store.getState().replace(update); store.getState().requestPrompt(update, 'release:1.7.0');
    store.getState().replace({ status }); store.getState().showPending();
    assert.equal(store.getState().prompt, null); assert.equal(store.getState().pendingPrompt, null);
  }
});
