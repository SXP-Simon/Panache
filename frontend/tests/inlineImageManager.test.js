const assert = require('assert').strict;

async function run() {
  const { collapseInlineImages, expandInlineImages, getReferencedImages } = await import('../src/utils/inlineImageManager.js');

  const testBase64 = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

  // 1. 折叠长 Base64 为短占位符
  const rawText = `这是正文前\n![图示](${testBase64})\n这是正文后`;
  const { collapsedText, imageStore, imageList } = collapseInlineImages(rawText);

  assert.equal(collapsedText.includes(testBase64), false, '超长 Base64 必须被折叠消除');
  assert.equal(collapsedText.includes('![插图 1]'), true, '应当生成统一的短标记 ![插图 1]');
  assert.equal(imageList.length, 1, '引用的图片列表长度应为 1');
  assert.equal(imageList[0].scale, '100%', '缺省比例应为 100%');

  // 2. 带比例后缀的占位符测试
  const scaledText = `分析如下：\n![插图 1|50%]\n以及小图：![插图 1|30%]`;
  const refImages = getReferencedImages(scaledText, imageStore);
  assert.equal(refImages.length, 1);
  assert.equal(refImages[0].scale, '50%');

  // 3. 展开还原为真实 Markdown 标记
  const expanded = expandInlineImages(scaledText, imageStore);
  assert.equal(expanded.includes(testBase64), true, '展开后必须包含真实的 Base64 数据');
  assert.equal(expanded.includes('![插图 1|50%]'), true, '展开时必须保留比例后缀');

  // 4. cleanMarkdown 格式清洗保护测试
  const { cleanMarkdown } = await import('../src/utils/cleanMarkdown.js');
  const dirtyMarkdown = `# 大题分析\n* 第一部分：图表\n![插图 1|50%]\n* 结论：[项目链接](http://example.com)`;
  const cleaned = cleanMarkdown(dirtyMarkdown);
  assert.equal(cleaned.includes('![插图 1|50%]'), true, 'cleanMarkdown 必须完整保护带比例的短插图标记');
  assert.equal(cleaned.includes('#'), false, 'Markdown 标题符号应当被清洗');

  console.log('All inlineImageManager tests passed successfully!');
}

run().catch(err => {
  console.error(err);
  process.exitCode = 1;
});
