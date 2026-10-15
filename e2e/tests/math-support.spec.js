const { test, expect, openHome, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');

test('Markdown cleaning and LaTeX conversion preserve prose and mathematical structure', async ({ page }) => {
  await openHome(page);
  const input = page.getByTestId('text-input');
  await input.fill(String.raw`# Result
The result $\frac{a}{b}$ is useful. $a<b>c$
$\binom{n}{k}+x_A$ and $\unknown{x}$`);
  await page.getByTestId('clean-markdown-btn').click();
  await expect(input).toHaveValue(String.raw`Result
The result $\frac{a}{b}$ is useful. $a<b>c$
$\binom{n}{k}+x_A$ and $\unknown{x}$`);
  await page.getByTestId('convert-latex-btn').click();
  await expect(input).toHaveValue(String.raw`Result
The result (a)/(b) is useful. a<b>c
C(n, k)+x_(A) and $\unknown{x}$`);
});

test('converted nested fractions and radicals render through the real backend', async ({ page }, testInfo) => {
  await openHome(page);
  await useSmallCanvas(page, { fontSize: 40, lineSpacing: 110 });
  await page.getByTestId('width-input').fill('800');
  await page.getByTestId('height-input').fill('600');
  await page.getByTestId('text-input').fill(String.raw`$\frac{\sqrt{a+\frac{b}{c}}}{d}$
$2\sqrt{x}+\sqrt[5]{y}$
$\mathbb{R}\subseteq\mathbb{C}$`);
  await page.getByTestId('convert-latex-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue('(√(a+(b)/(c)))/(d)\n2√(x)+⁵√(y)\nℝ⊆ℂ');
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  await page.getByTestId('preview-image').screenshot({ path: testInfo.outputPath('math-preview.png') });
});
