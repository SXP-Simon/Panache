const { test, expect, openHome, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');
const fs = require('node:fs/promises');

const homework = String.raw`# 电路与信号作业
* 元件参数：$R=\SI{4.7}{\kilo\ohm},\ C=\SI{100}{\nano\farad}$
* 交流阻抗：$Z=R+j\omega L+\frac{1}{j\omega C}$
* 低通响应：$H(j\omega)=\frac{1}{1+j\omega RC}$
* 拉普拉斯变换：$\mathcal{L}\{f(t)\}=F(s)$
* 高斯定理：$\oiint_S\mathbf{E}\cdot\mathrm{d}\mathbf{S}=\frac{Q}{\varepsilon_0}$
* 节点方程：$\begin{pmatrix}G_1+G_2&-G_2\\-G_2&G_2+G_3\end{pmatrix}\begin{pmatrix}U_1\\U_2\end{pmatrix}=\begin{pmatrix}I_1\\I_2\end{pmatrix}$
* 单位阶跃：$u(t)=\begin{cases}0&t<0\\1&t\ge0\end{cases}$

## 实验记录
| **参数** | 表达式 | 单位 |
| --- | --- | --- |
| 电阻 | $R$ | $\Omega$ |
| 导数 | $\dot{x}+\ddot{x}$ | $\si{\metre\per\second\squared}$ |
| 变体符号 | $\vartheta,\varphi,\varrho,\varepsilon$ | 无 |
`;

for (const style of ['neat', 'casual']) {
  test(`engineering homework ${style} cleans, converts and renders through the real engine`, async ({page}, testInfo) => {
    await openHome(page);
    await page.getByTestId('builtin-preset-select').selectOption('clean');
    await page.getByTestId('font-select').selectOption({label: style === 'neat' ? '霞鹜文楷.ttf' : '云烟体.ttf'});
    await page.getByTestId('underlined-checkbox').uncheck();
    await page.getByTestId('variation-settings-toggle').click();
    await page.getByTestId('ink-depth-sigma-input').fill(style === 'neat' ? '0' : '12');
    if (style === 'casual') {
      await page.getByTestId('font-size-sigma-input').fill('1');
      await page.getByTestId('perturb-x-sigma-input').fill('2');
      await page.getByTestId('perturb-y-sigma-input').fill('2');
      await page.getByTestId('perturb-theta-sigma-input').fill('0.04');
    }
    await useSmallCanvas(page, {fontSize: 70, lineSpacing: 130});
    await page.getByTestId('width-input').fill('2000');
    await page.getByTestId('height-input').fill('2200');
    const input = page.getByTestId('text-input');
    await input.fill(homework);
    await page.getByTestId('clean-markdown-btn').click();
    await expect(input).toHaveValue(/\\begin\{array\}/);
    await page.getByTestId('convert-latex-btn').click();
    await expect(input).toHaveValue(/⟦/);
    const converted = await input.inputValue();
    expect(converted).not.toMatch(/\\(?:SI|si|mathcal|oiint|begin|end|dot|ddot|vartheta|varphi|varrho|varepsilon)\b/);
    expect(converted).toContain('4.7');
    expect(converted).toContain('Ω');
    expect(converted).toContain('⟦');
    expect(converted).toContain('⟦ pmatrix:');
    expect(converted).toContain('⟦ cases:');
    expect(converted).toContain('ϑ');
    await page.getByTestId('preview-btn').click();
    await expectPreviewImageLoaded(page);
    const image = page.getByTestId('preview-image');
    // Save the real full-resolution output, not merely a screenshot of an <img>.
    const bytes = await image.evaluate(async (element) => {
      const response = await fetch(element.src);
      return Array.from(new Uint8Array(await response.arrayBuffer()));
    });
    const output = testInfo.outputPath('engineering-homework.png');
    await fs.writeFile(output, Buffer.from(bytes));
    await testInfo.attach('engineering-homework', {path: output, contentType:'image/png'});
  });
}

test('programming examples and reference links survive the cleanup button', async ({page}) => {
  await openHome(page);
  const source = '# 程序\n```cpp\n#include <stdio.h>\n    *p = a * b;\n```\n[说明](https://example.invalid/RC_(filter))';
  await page.getByTestId('text-input').fill(source);
  await page.getByTestId('clean-markdown-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue('程序\n#include <stdio.h>\n    *p = a * b;\n说明');
});
