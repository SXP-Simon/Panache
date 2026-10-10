const assert = require("assert").strict;

const tests = [];
function test(name, run) {
  tests.push({ name, run });
}

const inlineModule = import("../src/utils/inlineImageManager.js");
const cleanModule = import("../src/utils/cleanMarkdown.js");

const dummyBase64_1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
const dummyBase64_2 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEklEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test("collapses long base64 markdown images to lightweight short placeholders", async () => {
  const { collapseInlineImages } = await inlineModule;
  const rawText = `这是题目\n![插图](${dummyBase64_1})\n请结合上图作答。`;
  const { collapsedText, imageStore, imageList } = collapseInlineImages(rawText);

  assert.equal(collapsedText, "这是题目\n![插图 1]\n请结合上图作答。");
  assert.equal(imageStore["img_1"], dummyBase64_1);
  assert.equal(imageList.length, 1);
  assert.equal(imageList[0].index, 1);
});

test("expands short placeholders back to full markdown base64 before generation", async () => {
  const { expandInlineImages } = await inlineModule;
  const store = {
    img_1: dummyBase64_1,
    img_2: dummyBase64_2
  };
  const collapsedText = "步骤一：\n![插图 1]\n步骤二：\n![插图 2]\n完。";
  const expanded = expandInlineImages(collapsedText, store);

  assert.ok(expanded.includes(dummyBase64_1));
  assert.ok(expanded.includes(dummyBase64_2));
  assert.ok(expanded.includes("![插图 1]("));
  assert.ok(expanded.includes("![插图 2]("));
});

test("cleanMarkdown protects both short placeholders and raw inline base64 images", async () => {
  const { cleanMarkdown } = await cleanModule;
  const inputWithShort = "# 实验报告\n* 第一部分：电路图\n![插图 1]\n* 结论：[项目链接](http://example.com)";
  const outputShort = cleanMarkdown(inputWithShort);

  assert.ok(outputShort.includes("![插图 1]"));
  assert.ok(outputShort.includes("结论：项目链接"));
  assert.ok(!outputShort.includes("#"));

  const inputWithRawBase64 = `### 思考题\n> 如图所示\n![插图](${dummyBase64_1})\n请计算。`;
  const outputRaw = cleanMarkdown(inputWithRawBase64);
  assert.ok(outputRaw.includes(dummyBase64_1));
  assert.ok(outputRaw.includes("如图所示"));
});

async function runAll() {
  let passed = 0;
  for (const { name, run } of tests) {
    try {
      await run();
      passed++;
      console.log(`✓ ${name}`);
    } catch (e) {
      console.error(`✗ ${name}`);
      console.error(e);
      process.exitCode = 1;
    }
  }
  console.log(`\nPassed ${passed} / ${tests.length} tests.`);
}

runAll();
