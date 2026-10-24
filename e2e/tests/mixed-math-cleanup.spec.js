const { test, expect, openHome, fillText } = require('./fixtures');

const source = String.raw`我们测试 f'(x) = 3x^2：
 * 左边：\int_{-1}^{1} x^2 dx = \left. \frac{1}{3}x^3 \right\vert{}_{-1}^{1} = \frac{2}{3}
 * 右边：\frac{1}{2}\left[ (\frac{1}{2}-\frac{1}{2\sqrt{3}})^3 + (\frac{1}{2}+\frac{1}{2\sqrt{3}})^3 \right]
   展开：2 \times \left( \frac{1}{8} + \frac{1}{8} \right) = \frac{1}{2}`;

for (const repetitions of [1, 2]) {
  test(`mixed numerical integration cleanup: ${repetitions} cleanup click(s)`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openHome(page);
    await fillText(page, source);
    for (let i = 0; i < repetitions; i++) await page.getByTestId('prepare-text-btn').click();
    await expect(page.getByTestId('text-input')).toHaveValue(/f'\(x\) = 3x²/);
    const result = await page.getByTestId('text-input').inputValue();
    expect(result).not.toMatch(/\\(?:left|right|frac|sqrt|int)|\^|^[ \t]+(?:[*+-]|展开)/m);
    expect(result).toContain('∫');
    expect(result).toContain('展开：');
  });
}

test('standalone parenthesized power enables conversion action', async ({ page }) => {
  await openHome(page);
  await fillText(page, '计算 (x)^2 和 [x+1]^3');
  await page.getByTestId('prepare-text-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue('计算 (x)² 和 [x+1]³');
});
