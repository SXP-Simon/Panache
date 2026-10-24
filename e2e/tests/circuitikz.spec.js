const { test, expect, openHome, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');
const fixtures = require('../fixtures/circuitikz.json');
const fs = require('node:fs/promises');
const path = require('node:path');

const circuit = (id) => fixtures.find((entry) => entry.id === id).source;
const source = '# 常见作业电路\n\nRC 低通电路\n' + circuit('rc-lowpass') +
  '\n\nRLC 交流串联电路\n' + circuit('rlc-ac') +
  '\n\n二极管桥与负载\n' + circuit('diode-bridge') +
  '\n\n阻抗：$Z=R+j\\omega L+\\frac{1}{j\\omega C}$';

for (const style of ['neat', 'casual']) {
  test(`circuitikz ${style} renders intact circuits through the real application`, async ({page}) => {
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
      await page.getByTestId('perturb-theta-sigma-input').fill('0.03');
    }
    await useSmallCanvas(page, {fontSize: 54, lineSpacing: 100});
    await page.getByTestId('width-input').fill('1800');
    await page.getByTestId('height-input').fill('2300');
    await page.getByTestId('margin-left-input').fill('80');
    await page.getByTestId('margin-top-input').fill('70');
    const input = page.getByTestId('text-input');
    await input.fill(source);
    await page.getByTestId('prepare-text-btn').click();
    await expect(input).toHaveValue(/^常见作业电路/);
    await expect(input).toHaveValue(/阻抗：Z=R\+jωL/);
    const converted = await input.inputValue();
    for (const id of ['rc-lowpass','rlc-ac','diode-bridge']) {
      expect(converted).toContain(circuit(id));
    }
    await page.getByTestId('preview-btn').click();
    await expectPreviewImageLoaded(page);
    await expect(input).toHaveValue(converted);
    const bytes = await page.getByTestId('preview-image').evaluate(async (element) => {
      const response = await fetch(element.src);
      return Array.from(new Uint8Array(await response.arrayBuffer()));
    });
    const output = path.resolve(__dirname, '../../preview_outputs/circuits');
    await fs.mkdir(output, {recursive:true});
    await fs.writeFile(path.join(output, `web-${style}.png`), Buffer.from(bytes));
    await page.setViewportSize({width:1600,height:1100});
    await page.screenshot({path:path.join(output, `web-${style}-workspace.png`)});
  });
}
