const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
test('NSIS update override refuses running processes without invoking builder taskkill branch', async () => {
  const build = require('../package.json').build;
  assert.equal(build.nsis.include, 'installer.nsh');
  const source = await fs.readFile(path.resolve(__dirname, '../installer.nsh'), 'utf8');
  const update = source.split('${Else}')[0];
  assert.ok(update.includes('${If} ${isUpdated}'));
  assert.ok(update.includes('!insertmacro FIND_PROCESS'));
  assert.ok(update.includes('SetErrorLevel 32'));
  assert.ok(update.includes('Quit'));
  assert.ok(!/taskkill|KillProcess|_CHECK_APP_RUNNING/i.test(update));
  assert.ok(source.split('${Else}')[1].includes('!insertmacro _CHECK_APP_RUNNING'));
  assert.ok(source.includes('!include "getProcessInfo.nsh"'));
  assert.ok(source.includes('Var pid'));
});
