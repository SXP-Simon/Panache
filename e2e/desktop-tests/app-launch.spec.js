// 打包产物的启动路径：Electron 拉起后端 exe → 端口握手 → 同源加载站点。
// 这些是源码版 E2E 覆盖不到的集成路径（也是历史上翻过车的地方）。
const fs = require("fs");
const path = require("path");
const { test, expect } = require("./fixtures");
const { launchDesktopApp, resetHome, httpRequest, waitForBackendDown } = require("./launch");

const PACKAGED_VERSION = require(path.resolve(__dirname, "..", "..", "desktop", "package.json"))
  .version;

test.describe("桌面版启动与打包完整性", () => {
  test("产品更名保留显式 Chromium 配置与独立实例锁", async ({ desktop }) => {
    const identity = await desktop.app.evaluate(({ app }) => ({
      explicit: app.commandLine.getSwitchValue("user-data-dir"), userData: app.getPath("userData"), sessionData: app.getPath("sessionData"),
    }));
    expect(identity.explicit).toBeTruthy();
    expect(fs.realpathSync(identity.userData)).toBe(fs.realpathSync(identity.explicit));
    expect(fs.realpathSync(identity.sessionData)).toBe(fs.realpathSync(identity.userData));
  });

  test("发行包保留完整的项目许可", async ({ desktop }) => {
    const license = await desktop.app.evaluate(async ({ app, BrowserWindow }) => {
      const viewer = new BrowserWindow({
        show: false,
        webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: true },
      });
      try {
        await viewer.loadFile(`${app.getAppPath()}/LICENSE`);
        return await viewer.webContents.executeJavaScript("document.body.textContent");
      } finally {
        viewer.destroy();
      }
    });
    const source = fs.readFileSync(path.resolve(__dirname, "..", "..", "LICENSE"), "utf8");
    expect(license.replaceAll("\r\n", "\n").trim()).toBe(source.replaceAll("\r\n", "\n").trim());
  });

  test("窗口加载真实站点：字体来自打包资源，页脚版本号是打包版本", async ({ desktop }) => {
    await resetHome(desktop);

    // 字体文件是随包发的资源（FONT_ASSETS_BUNDLED_DIR），少了它们生成会直接失败
    const fonts = await httpRequest({ port: desktop.port, reqPath: "/api/fonts_info" });
    expect(fonts.status).toBe(200);
    const names = JSON.parse(fonts.body.toString("utf8"));
    expect(names.length).toBeGreaterThan(0);
    expect(names).toContain("云烟体.ttf");

    // UI 字库必须包含在 dist 内，任意中文的完整字库也由同一个本地后端提供。
    const interfaceFonts = await desktop.page.evaluate(async () => {
      const faces = await document.fonts.load('16px "LXGW WenKai"', '中文 English 0123 龘');
      return faces.map((face) => ({ family: face.family, status: face.status }));
    });
    expect(interfaceFonts.length).toBeGreaterThanOrEqual(2);
    for (const face of interfaceFonts) {
      expect(face.family.replaceAll(/["']/g, "")).toBe("LXGW WenKai");
      expect(face.status).toBe("loaded");
    }

    // 页脚显示的是 /api/version 的结果，链路是 app.getVersion() → 后端 → 前端
    await expect(desktop.page.getByTestId("app-version")).toContainText(PACKAGED_VERSION);
  });

  test("数据目录落在平台默认位置：握手端口与站点一致，sqlite 已初始化", async ({ desktop }) => {
    const content = async () => fs.readFileSync(desktop.logPath, "utf8");

    // 握手行是 Electron 从后端 stdout 解析出来的那一行，必须原样落进日志文件
    await expect
      .poll(async () => (await content()).match(/HANDWRITING_BACKEND (\{.*\})/)?.[1] ?? null, {
        timeout: 20_000,
      })
      .not.toBeNull();

    const payload = JSON.parse((await content()).match(/HANDWRITING_BACKEND (\{.*\})/)[1]);
    expect(payload.type).toBe("ready");
    expect(payload.port).toBe(desktop.port);

    // 打包后 __file__ 不可信，数据必须落到可写目录：任务队列与日志都在这里
    expect(fs.existsSync(path.join(desktop.dataDir, "tasks.db"))).toBe(true);
    expect(fs.existsSync(path.join(desktop.dataDir, "logs"))).toBe(true);
    expect(fs.existsSync(path.join(desktop.dataDir, "temp"))).toBe(true);
  });

  test("独立启动与错误页使用随包携带的完整文楷字库", async ({ desktop }) => {
    const result = await desktop.app.evaluate(async ({ app, BrowserWindow }) => {
      const splash = new BrowserWindow({
        show: false,
        webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: true },
      });
      try {
        await splash.loadFile(`${app.getAppPath()}/splash.html`);
        return await splash.webContents.executeJavaScript(`(async () => {
          const fonts = await document.fonts.load('16px "LXGW WenKai"', '中文 English 0123 龘');
          window.showError('启动失败 Error 龘');
          return {
            faces: fonts.map(face => ({ family: face.family, status: face.status })),
            heading: getComputedStyle(document.querySelector('h1')).fontFamily,
            error: getComputedStyle(document.querySelector('#error')).fontFamily,
            stylesheets: Array.from(document.styleSheets, sheet => sheet.href).filter(Boolean)
          };
        })()`);
      } finally {
        splash.destroy();
      }
    });
    expect(result.faces.length).toBeGreaterThanOrEqual(2);
    for (const face of result.faces) {
      expect(face.family.replaceAll(/["']/g, "")).toBe("LXGW WenKai");
      expect(face.status).toBe("loaded");
    }
    expect(result.heading.replaceAll(/["']/g, "")).toBe("LXGW WenKai");
    expect(result.error.replaceAll(/["']/g, "")).toBe("LXGW WenKai");
    expect(result.stylesheets.length).toBeGreaterThanOrEqual(1);
    expect(result.stylesheets.every((url) => url.startsWith("file://"))).toBe(true);
  });

  test("站点与静态资源由打包的 dist 提供（同源，无需跨域）", async ({ desktop }) => {
    const index = await httpRequest({ port: desktop.port, reqPath: "/" });
    expect(index.status).toBe(200);
    expect(index.headers["content-type"]).toContain("text/html");
    const html = index.body.toString("utf8");
    expect(html).toContain('<div id="app">');

    const assetPath = html.match(/src="(\/assets\/[^"]+\.js)"/)?.[1];
    expect(assetPath, "首页 HTML 里没有引用打包后的 js").toBeTruthy();
    const asset = await httpRequest({ port: desktop.port, reqPath: assetPath });
    expect(asset.status).toBe(200);
    expect(asset.body.length).toBeGreaterThan(1000);
  });

  test("关窗后后端跟着退出，不留孤儿进程", async () => {
    const desktop = await launchDesktopApp();
    const { port } = desktop;
    await desktop.close();

    // Electron 退出时 kill 后端；漏掉时 desktop_main.py 的父进程看门狗每 3 秒兜一次
    expect(await waitForBackendDown(port)).toBe(true);
  });
});
