const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs/promises');
const { createAfterPack } = require('../mac-sign.cjs');
const configuration = require('../package.json').build;

function context(platform = 'darwin') {
  const perFile = { entitlements: '/template/entitlements.mac.plist', hardenedRuntime: true, additionalArguments: ['--preserve-metadata=identifier'] };
  return { electronPlatformName: platform, appOutDir: '/构建 空格/mac-arm64', packager: {
    appInfo: { productFilename: 'Panache' }, config: { electronVersion: '33.4.11' }, platformSpecificBuildOptions: {},
    getOptionsForFile: async (app, mas) => { assert.ok(app.endsWith('Panache.app')); assert.equal(mas, false); return () => perFile; },
  } };
}
test('mac build signs ad-hoc with builder entitlements then strictly verifies and runs the packaged helper', async () => {
  const calls = [];
  await createAfterPack({ sign: async (options) => {
    assert.equal(options.identity, '-'); assert.equal(options.identityValidation, false);
    assert.equal(options.preAutoEntitlements, false); assert.equal(options.strictVerify, undefined);
    const settings = options.optionsForFile('helper');
    assert.equal(settings.hardenedRuntime, true); assert.equal(settings.timestamp, 'none');
    assert.equal(settings.entitlements, '/template/entitlements.mac.plist');
    assert.deepEqual(settings.additionalArguments, ['--preserve-metadata=identifier']);
    calls.push('sign');
  }, run: async (file, args) => { calls.push([file, args]); } })(context());
  assert.equal(calls[0], 'sign');
  assert.deepEqual(calls[1], ['/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', path.join('/构建 空格/mac-arm64', 'Panache.app')]]);
  assert.deepEqual(calls[2], [path.join('/构建 空格/mac-arm64', 'Panache.app/Contents/Resources/updater/panache-updater'), ['--self-check']]);
});
test('Windows and Linux packaging never invoke mac signing or system commands', async () => {
  const afterPack = createAfterPack({ sign: () => assert.fail('must not sign'), run: () => assert.fail('must not execute') });
  for (const platform of ['win32', 'linux']) await afterPack(context(platform));
});
test('signing or strict verification failures fail the build instead of publishing an unverifiable app', async () => {
  await assert.rejects(createAfterPack({ sign: async () => { throw new Error('sign failed'); }, run: () => assert.fail('must not run') })(context()), /sign failed/);
  await assert.rejects(createAfterPack({ sign: async () => {}, run: async (file) => { assert.equal(file, '/usr/bin/codesign'); throw new Error('verify failed'); } })(context()), /verify failed/);
});
test('hook runs before packaging on every mac build and current builder retains required Electron permissions', async () => {
  assert.equal(configuration.afterPack, './mac-sign.cjs');
  assert.equal(configuration.mac.identity, null);
  require('app-builder-lib');
  const { MacPackager } = require('app-builder-lib/out/macPackager');
  const getOptionsForFile = MacPackager.prototype.getOptionsForFile;
  assert.equal(typeof getOptionsForFile, 'function');
  const perFile = await getOptionsForFile.call({ resourceList: Promise.resolve([]), platformSpecificBuildOptions: {} }, '/fixture/Panache.app', false, {});
  for (const file of ['/fixture/Panache.app', '/fixture/Panache.app/Contents/Frameworks/Panache Helper.app', '/fixture/Panache.app/Contents/Resources/backend/handwriting-backend']) {
    const options = perFile(file);
    assert.equal(options.hardenedRuntime, true);
    const entitlements = await fs.readFile(options.entitlements, 'utf8');
    for (const permission of ['com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory', 'com.apple.security.cs.disable-library-validation']) assert.ok(entitlements.includes(`<key>${permission}</key>`));
  }
});
