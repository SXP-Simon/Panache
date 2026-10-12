// Flutter Web UI → 打包的 Python 后端 → 真实预览与下载。
const fs = require("fs");
const path = require("path");
const { test, expect } = require("./fixtures");
const { resetHome, waitForDownload } = require("./launch");

async function fillField(page, id, value) {
  const input = page.getByTestId(id).locator("input, textarea");
  await input.click();
  // Flutter 在下一帧完成 DOM 焦点与 TextEditingValue 同步，随后再输入。
  await input.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await input.fill(String(value));
  await input.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await input.press("Tab");
  await expect(input).toHaveValue(String(value));
}
async function useSmallCanvas(page) {
  for (const [id, value] of Object.entries({ width: 420, height: 320, font_size: 32, line_spacing: 45, top_margin: 20, bottom_margin: 20, left_margin: 20, right_margin: 20 })) {
    await fillField(page, id, value);
  }
}

test.describe("Flutter 打包版生成主流程", () => {
  test("输入文字并生成真实预览", async ({ desktop }) => {
    await resetHome(desktop);
    await useSmallCanvas(desktop.page);
    await fillField(desktop.page, "text-input", "你好世界");
    await desktop.page.getByTestId("preview-btn").click();
    await expect(desktop.page.getByTestId("preview-image")).toBeVisible();
  });
  for (const [id, extension, signature] of [["generate-image-btn", "zip", "PK"], ["generate-pdf-btn", "pdf", "%PDF-"]]) {
    test(`导出真实 ${extension}`, async ({ desktop }) => {
      await resetHome(desktop);
      await useSmallCanvas(desktop.page);
      await fillField(desktop.page, "text-input", "静夜思床前明月光疑是地上霜举头望明月低头思故乡");
      await desktop.page.getByTestId(id).click();
      const buffer = fs.readFileSync(await waitForDownload(desktop, `handwriting.${extension}`));
      expect(buffer.subarray(0, signature.length).toString("latin1")).toBe(signature);
      expect(buffer.length).toBeGreaterThan(1000);
      if (extension === "pdf") expect(buffer.length).toBeLessThan(24_000);
    });
  }
  test("上传文本并预览", async ({ desktop }) => {
    await resetHome(desktop);
    await useSmallCanvas(desktop.page);
    const importResponse = desktop.page.waitForResponse(response => response.url().endsWith("/api/textfileprocess"));
    const chooserPromise = desktop.page.waitForEvent("filechooser");
    await desktop.page.getByTestId("import-text").click();
    await (await chooserPromise).setFiles(path.join(__dirname, "..", "fixtures", "sample-letter.txt"));
    expect((await importResponse).status()).toBe(200);
    const input = desktop.page.getByTestId("text-input").locator("textarea");
    await expect(input).toBeEnabled();
    await input.click();
    await expect(input).toHaveValue(/这是一份用于端到端测试的文本文件。/);
    await desktop.page.getByTestId("preview-btn").click();
    await expect(desktop.page.getByTestId("preview-image")).toBeVisible();
  });
});
