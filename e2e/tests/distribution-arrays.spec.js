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
const expected = '于是，X 的分布律为\n[ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ]\n因此，Y 的分布律为\n[ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ]';

for (const order of [
  ['clean-markdown-btn', 'convert-latex-btn'],
  ['convert-latex-btn', 'clean-markdown-btn'],
]) {
  test(`distribution arrays convert and render: ${order.join(' then ')}`, async ({ page }) => {
    await openHome(page);
    await useSmallCanvas(page, { fontSize: 40, lineSpacing: 110 });
    await page.getByTestId('width-input').fill('2000');
    await page.getByTestId('height-input').fill('1000');
    const input = page.getByTestId('text-input');
    await input.fill(source);
    for (const action of order) await page.getByTestId(action).click();
    await expect(input).toHaveValue(expected);
    await page.getByTestId('preview-btn').click();
    await expectPreviewImageLoaded(page);
    await page.getByTestId('preview-image').screenshot({
      path: path.resolve(__dirname, `../../preview_outputs/distribution-arrays/web-${order[0]}.png`),
    });
    const png = await page.getByTestId('preview-image').evaluate(async (image) =>
      Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())),
    );
    fs.writeFileSync(
      path.resolve(__dirname, `../../preview_outputs/distribution-arrays/web-${order[0]}-full.png`),
      Buffer.from(png),
    );
  });
}
