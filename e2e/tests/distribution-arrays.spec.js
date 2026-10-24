const path = require('node:path');
const fs = require('node:fs');
const { test, expect, openHome, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');

const source = String.raw`于是，\(X\) 的分布律为
\[
\begin{array}{c|cccc}
X&0&1&2&3\\ \hline
P&\frac8{15}&\frac4{15}&\frac2{15}&\frac1{15}
\end{array}
\]
因此，Y 的分布律为
\[
\boxed{
\begin{array}{c|ccc}
Y&1&2&3\\ \hline
P&\frac13&\frac13&\frac13
\end{array}}
\]`;
const expected = '于是，X 的分布律为\n⟦ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ⟧\n因此，Y 的分布律为\n⟦ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ⟧';

for (const repetitions of [1, 2]) {
  test(`distribution arrays convert and render: ${repetitions} cleanup click(s)`, async ({ page }) => {
    await openHome(page);
    await useSmallCanvas(page, { fontSize: 70, lineSpacing: 120 });
    await page.getByTestId('width-input').fill('1600');
    await page.getByTestId('height-input').fill('1600');
    await page.getByTestId('underlined-checkbox').setChecked(repetitions === 2);
    const input = page.getByTestId('text-input');
    await input.fill(source);
    for (let i = 0; i < repetitions; i++) await page.getByTestId('prepare-text-btn').click();
    await expect(input).toHaveValue(expected);
    await page.getByTestId('preview-btn').click();
    await expectPreviewImageLoaded(page);
    await page.getByTestId('preview-image').screenshot({
      path: path.resolve(__dirname, `../../preview_outputs/distribution-arrays/web-${repetitions}.png`),
    });
    const png = await page.getByTestId('preview-image').evaluate(async (image) =>
      Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())),
    );
    fs.writeFileSync(
      path.resolve(__dirname, `../../preview_outputs/distribution-arrays/web-${repetitions}-full.png`),
      Buffer.from(png),
    );
  });
}

 test('Markdown probability table renders a handwriting grid', async ({ page }) => {
    await openHome(page);
    await useSmallCanvas(page, { fontSize: 70, lineSpacing: 120 });
    await page.getByTestId('width-input').fill('1600');
    await page.getByTestId('height-input').fill('1600');
    const input = page.getByTestId('text-input');
    await input.fill('分布律与计算记录\n| X | 0 | 1 | 2 | 3 |\n|---|---|---|---|---|\n| P | $\\frac8{15}$ | $\\frac4{15}$ | $\\frac2{15}$ | $\\frac1{15}$ |\n\n| 项目 | 结果 |\n|---|---|\n| 期望 | $\\frac{11}{15}$ |\n| 说明 | text $x$ unit |');
    await page.getByTestId('prepare-text-btn').click();
    await expect(input).toHaveValue(/⟦/);
    await page.getByTestId('preview-btn').click();
    await expectPreviewImageLoaded(page);
    const png = await page.getByTestId('preview-image').evaluate(async (image) => Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())));
    fs.writeFileSync(path.resolve(__dirname, '../../preview_outputs/distribution-arrays/web-markdown-grid-full.png'), Buffer.from(png));
 });
