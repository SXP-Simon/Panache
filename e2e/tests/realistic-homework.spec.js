const { test, expect, openHome, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');
const pages = require('../fixtures/realistic-homework.cjs');
const circuits = require('../fixtures/realistic-circuits.json');
const fs = require('node:fs/promises');
const path = require('node:path');

for (const [index, source] of pages.entries()) {
  test(`realistic homework ${index + 1} survives cleanup, conversion and real rendering`, async ({page}) => {
    await openHome(page);
    await page.getByTestId('builtin-preset-select').selectOption('clean');
    await page.getByTestId('font-select').selectOption({label:'云烟体.ttf'});
    await page.getByTestId('underlined-checkbox').check();
    await useSmallCanvas(page, {fontSize:52, lineSpacing:100});
    await page.getByTestId('width-input').fill('1800');
    await page.getByTestId('height-input').fill('2300');
    await page.getByTestId('margin-left-input').fill('85');
    await page.getByTestId('margin-top-input').fill('70');
    // Exercise the real custom-paper upload path with unobtrusive notebook rules.
    const paper = await page.evaluate(() => {
      const canvas = document.createElement('canvas');
      canvas.width = 1800;
      canvas.height = 2300;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, 1800, 2300);
      ctx.strokeStyle = '#cbdbe2';
      ctx.lineWidth = 2;
      for (let y = 170; y < 2280; y += 100) {
        ctx.beginPath();
        ctx.moveTo(85, y);
        ctx.lineTo(1780, y);
        ctx.stroke();
      }
      return canvas.toDataURL('image/png').split(',')[1];
    });
    await page.getByTestId('background-image-input').setInputFiles({
      name:'notebook.png', mimeType:'image/png', buffer:Buffer.from(paper, 'base64'),
    });
    await page.getByTestId('detect-background-cancel').click();
    await expect(page.getByTestId('modal')).toHaveCount(0);
    const input = page.getByTestId('text-input');
    await input.fill(source);
    await page.getByTestId('clean-markdown-btn').click();
    await expect(input).toHaveValue(new RegExp('^' + source.split('\n')[0].slice(2)));
    await page.getByTestId('convert-latex-btn').click();
    await expect(input).not.toHaveValue(/\\(?:ce|qty|SI|frac|begin\{(?:aligned|pmatrix|array))\b/);
    if (index === 6) await expect(input).not.toHaveValue(/\\(?:dv|pdv|abs|norm)\b/);
    const converted = await input.inputValue();
    if (index < circuits.length) expect(converted).toContain(circuits[index].source);
    if (index === 4) {
      expect(converted).toContain('⟦ ──');
      expect(converted).toContain('| X | 0 | 1 | 2 | 3 |');
    }
    if (index === 5) {
      expect(converted).toContain('NH₄');
      expect(converted).not.toMatch(/\\(?:ce|qty|SI)\b/);
    }
    await page.getByTestId('preview-btn').click();
    await expectPreviewImageLoaded(page);
    await expect(input).toHaveValue(converted);
    const bytes = await page.getByTestId('preview-image').evaluate(async element => {
      const response = await fetch(element.src);
      return Array.from(new Uint8Array(await response.arrayBuffer()));
    });
    const output = path.resolve(__dirname, '../../preview_outputs/realistic-homework');
    await fs.mkdir(output, {recursive:true});
    await fs.writeFile(path.join(output, `web-${index + 1}.png`), Buffer.from(bytes));
    await fs.writeFile(path.join(output, `web-${index + 1}.txt`), converted);
  });
}
