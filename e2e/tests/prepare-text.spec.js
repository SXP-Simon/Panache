const { test, expect, openHome, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');
const path = require('node:path');
const fs = require('node:fs/promises');
const formulas = require('../../frontend/tests/fixtures/automata-latex.json');
const [, formula, expected] = formulas[0];
const source = '# 正规式作业\n\n---\n**能被 5 整除的十进制整数**\n$$' + formula + '$$';

for (const width of [390, 1440]) {
  test(`prepare text preserves code, repeated clicks and undo at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await openHome(page);
    const input = page.getByTestId('text-input');
    const original = source + '\n```cpp\n    *p = a * b;\n    x^2;\n```';
    await input.fill(original);
    await expect(page.getByTestId('convert-latex-btn')).toHaveCount(0);
    await expect(page.getByTestId('clean-markdown-btn')).toHaveCount(0);
    await page.getByTestId('prepare-text-btn').click();
    const output = '正规式作业\n能被 5 整除的十进制整数\n' + expected + '\n    *p = a * b;\n    x^2;';
    await expect(input).toHaveValue(output);
    await page.getByTestId('prepare-text-btn').click();
    await expect(input).toHaveValue(output);
    const directory = path.resolve(__dirname, '../../preview_outputs/prepare-text');
    await fs.mkdir(directory, { recursive: true });
    await page.getByTestId('text-panel').screenshot({ path: path.join(directory, `editor-${width}.png`) });
    await page.getByTestId('prepare-text-undo').click();
    await expect(input).toHaveValue(original);
    await page.getByTestId('prepare-text-btn').click();
    await expect(input).toHaveValue(output);
  });
}

test('lazy text preparation cannot overwrite an edit made during loading', async ({ page }) => {
  await openHome(page);
  let resume;
  const gate = new Promise(resolve => { resume = resolve; });
  await page.route('**/src/utils/prepareHandwritingText.ts*', async route => {
    await gate;
    await route.continue();
  });
  const input = page.getByTestId('text-input');
  await input.fill(source);
  await page.getByTestId('prepare-text-btn').click();
  await expect(page.getByTestId('prepare-text-btn')).toBeDisabled();
  await input.fill('新的内容');
  resume();
  await expect(page.getByTestId('prepare-text-btn')).toBeEnabled();
  await expect(input).toHaveValue('新的内容');
  await expect(page.getByTestId('prepare-text-undo')).toHaveCount(0);
});

test('changing table mode reuses original markup and keeps code literal', async ({ page }) => {
  await openHome(page);
  const source = '| X | P |\n|---|---|\n| 0 | $\\frac13$ |\n`x^2`';
  const input = page.getByTestId('text-input');
  await input.fill(source);
  await page.getByTestId('prepare-text-btn').click();
  await expect(input).toHaveValue(/⟦.*⅓.*⟧\nx\^2/);
  await page.getByTestId('markdown-table-mode').selectOption('list');
  await page.getByTestId('prepare-text-btn').click();
  await expect(input).not.toHaveValue(/⟦/);
  await expect(input).toHaveValue(/⅓.*\nx\^2/s);
  await page.getByTestId('prepare-text-undo').click();
  await expect(input).toHaveValue(source);
});

test('automata formula renders after one preparation action', async ({ page }) => {
  await openHome(page);
  await page.getByTestId('builtin-preset-select').selectOption('clean');
  await page.getByTestId('font-select').selectOption({ label: '霞鹜文楷.ttf' });
  await useSmallCanvas(page, { fontSize: 60, lineSpacing: 110 });
  await page.getByTestId('width-input').fill('2300');
  await page.getByTestId('height-input').fill('650');
  await page.getByTestId('underlined-checkbox').check();
  await page.getByTestId('text-input').fill(source);
  await page.getByTestId('prepare-text-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue('正规式作业\n能被 5 整除的十进制整数\n' + expected);
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  const bytes = await page.getByTestId('preview-image').evaluate(async image =>
    Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())));
  const directory = path.resolve(__dirname, '../../preview_outputs/prepare-text');
  await fs.mkdir(directory, { recursive: true });
  await fs.writeFile(path.join(directory, 'automata-render.png'), Buffer.from(bytes));
});
