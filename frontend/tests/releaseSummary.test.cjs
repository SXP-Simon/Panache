const test = require('node:test');
const assert = require('node:assert/strict');
const modulePromise = import('../src/features/updates/releaseSummary.ts');
test('release summaries remove source scopes and commit hashes and exclude the download guide', async () => {
  const { summarizeReleaseNotes: summarize } = await modulePromise;
  const notes = '# 1.7.0\n\n### Features\n* **fe/src/features/updates:** 支持手动检查更新 ([abcdef1](https://github.com/SXP-Simon/Panache/commit/abcdef1))\n* **desktop:** 下载后可安装新版本 (abcdef12)\n* **scripts:** 校验构建来源\n<!-- download-guide -->\n* 下载 Windows 安装包\n';
  assert.deepEqual(summarize(notes), ['支持手动检查更新', '下载后可安装新版本']);
});
test('release summaries are bounded, plain text and deduplicated', async () => {
  const { summarizeReleaseNotes: summarize } = await modulePromise;
  const lines = ['- fix(fe/src): <b>修复图片插入</b>\n- fix(fe/src): 修复图片插入', ...Array.from({ length: 12 }, (_, index) => `- 功能${index}`)].join('\n');
  assert.deepEqual(summarize(lines), ['修复图片插入', '功能0', '功能1', '功能2', '功能3', '功能4']);
  assert.equal(summarize('- ' + '长'.repeat(500))[0].length, 160);
});
test('download tables, code blocks and unstructured implementation prose are omitted', async () => {
  const { summarizeReleaseNotes: summarize } = await modulePromise;
  assert.deepEqual(summarize('实现细节的长段落，不应直接展示。'), []);
  assert.deepEqual(summarize('## 下载哪个包\n- Panache.exe\n```\n- shell command\n```\n| Assets | SHA256 |'), []);
  assert.deepEqual(summarize('```\n- source code\n```\n## Bug fixes\n- **be/math:** 修复分数对齐\n## Installation\n- Run installer'), ['修复分数对齐']);
});
