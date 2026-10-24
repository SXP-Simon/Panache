"use strict";

const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const { createRequire } = require("node:module");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");
const { chromium } = createRequire(path.join(root, "e2e/package.json"))("@playwright/test");
const dist = path.join(root, "frontend/dist");
const mime = {
  ".js": "text/javascript", ".css": "text/css", ".html": "text/html",
  ".json": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
  ".webmanifest": "application/manifest+json",
};

async function iconBytes(page, urls) {
  return page.evaluate(async (sources) => Promise.all(sources.map(async (url) => {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Icon request failed: ${url}`);
    return { url, bytes: [...new Uint8Array(await response.arrayBuffer())] };
  })), urls);
}

async function loadWenKai(page) {
  return page.evaluate(async () => {
    const faces = await document.fonts.load('16px "LXGW WenKai"', '中文 English 0123 龘');
    return faces.map((face) => ({ family: face.family.replaceAll(/["']/g, ''), status: face.status }));
  });
}

async function wenKaiSources(page) {
  return page.evaluate(() => {
    const urls = new Set();
    function inspectRules(rules, base) {
      for (const rule of rules) {
        if (rule instanceof CSSFontFaceRule && rule.style.fontFamily.replaceAll(/["']/g, '').trim() === 'LXGW WenKai') {
          for (const match of rule.style.getPropertyValue('src').matchAll(/url\(["']?([^"')]+)["']?\)/g))
            urls.add(new URL(match[1], base).href);
        } else if (rule instanceof CSSImportRule && rule.styleSheet) {
          inspectRules(rule.styleSheet.cssRules, rule.styleSheet.href ?? base);
        } else if ('cssRules' in rule) {
          inspectRules(rule.cssRules, base);
        }
      }
    }
    for (const sheet of document.styleSheets) inspectRules(sheet.cssRules, sheet.href ?? location.href);
    return [...urls];
  });
}

async function expectOfflineCustomGlyphs(page, session) {
  await page.evaluate(async () => {
    for (const [id, text] of [['offline-font-cn', '龘'], ['offline-font-en', 'English']]) {
      const element = document.createElement('p');
      element.id = id;
      element.textContent = text;
      element.style.font = '24px "LXGW WenKai"';
      document.body.append(element);
    }
    await document.fonts.ready;
  });
  await session.send('DOM.enable');
  await session.send('CSS.enable');
  const { root: documentNode } = await session.send('DOM.getDocument');
  for (const id of ['offline-font-cn', 'offline-font-en']) {
    const { nodeId } = await session.send('DOM.querySelector', { nodeId: documentNode.nodeId, selector: `#${id}` });
    const { fonts } = await session.send('CSS.getPlatformFontsForNode', { nodeId });
    assert.ok(fonts.length > 0, `${id} must render real glyphs`);
    assert.ok(fonts.every((font) => font.isCustomFont && font.glyphCount > 0 && /LXGW.*WenKai/i.test(font.familyName)), `${id} fell back to an installed font: ${JSON.stringify(fonts)}`);
  }
}

for (const script of ["service-worker.js", "sw.js"]) {
  test(`cached legacy ${script} upgrades without running the React entry point`, { timeout: 45_000 }, async () => {
    let migrated = false;
    let networkFontRequests = 0;
    let legacyIconRequests = 0;
    const oldIcon = '<svg xmlns="http://www.w3.org/2000/svg"><text>legacy cached icon</text></svg>';
    const iconVersion = createHash('sha256').update(await fs.readFile(path.join(root, 'frontend/src/assets/brand.svg'))).digest('hex').slice(0, 12);
    const legacyPage = `<!doctype html><title>Legacy cached page</title><p id="legacy">Old Vue/ad page</p><script>navigator.serviceWorker.register('/${script}')</script>`;
    const legacyWorker = `
      self.addEventListener('install', event => event.waitUntil((async () => {
        const cache = await caches.open('workbox-precache-v2-' + self.registration.scope);
        await cache.put(new URL('/index.html', self.location.href), new Response(${JSON.stringify(legacyPage)}, {headers: {'content-type': 'text/html'}}));
        await cache.put(new URL('/assets/legacy-ad.js', self.location.href), new Response('old ad'));
        await (await caches.open('workbox-precache-v2-' + new URL('/other/', self.location.href))).put('/other/keep', new Response('keep'));
        await (await caches.open('unrelated-user-cache')).put('/keep', new Response('keep'));
        const api = await caches.open('api-cache');
        await api.put('/api/old', new Response('stale project response'));
        await api.put('/other/api/keep', new Response('keep'));
        await self.skipWaiting();
      })()));
      self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
      self.addEventListener('fetch', event => {
        if (event.request.mode === 'navigate') event.respondWith(caches.match('/index.html'));
      });
    `;
    const server = http.createServer((request, response) => {
      void (async () => {
        const requestUrl = new URL(request.url ?? "/", "http://localhost");
        const pathname = requestUrl.pathname;
        if (pathname.endsWith('.woff2')) networkFontRequests += 1;
        response.setHeader("Cache-Control", "no-store");
        if (pathname === '/icon.svg' && !requestUrl.search && !migrated) {
          legacyIconRequests += 1;
          response.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
          response.setHeader('Content-Type', 'image/svg+xml');
          response.end(oldIcon);
        } else if (pathname === `/${script}` && !migrated) {
          response.setHeader("Content-Type", "text/javascript");
          response.end(legacyWorker);
        } else if (!migrated && (pathname === "/" || pathname === "/index.html")) {
          response.setHeader("Content-Type", "text/html");
          response.end(legacyPage);
        } else if (pathname.startsWith("/api/")) {
          response.setHeader("Content-Type", "application/json");
          response.end(pathname.endsWith("fonts_info") ? '["test.ttf"]' : pathname.endsWith("version") ? '{"version":"test"}' : '{"status":"success","source":"network-only"}');
        } else {
          const file = path.resolve(dist, `.${pathname === "/" ? "/index.html" : pathname}`);
          if (!file.startsWith(`${dist}${path.sep}`)) throw new Error("Invalid test request");
          response.setHeader("Content-Type", mime[path.extname(file)] ?? "application/octet-stream");
          response.end(await fs.readFile(file));
        }
      })().catch(() => {
        response.statusCode = 404;
        response.end();
      });
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    assert.ok(address && typeof address === "object");
    const origin = `http://127.0.0.1:${address.port}`;
    let browser;
    try {
      browser = await chromium.launch();
      const applicationContext = await browser.newContext();
      let offline = false;
      const offlineFontResponses = new Map();
      const offlineIconResponses = new Map();
      applicationContext.on('response', (response) => {
        if (offline && new URL(response.url()).pathname.endsWith('.woff2'))
          offlineFontResponses.set(response.url(), response.fromServiceWorker());
        if (offline && new URL(response.url()).searchParams.has('v'))
          offlineIconResponses.set(response.url(), response.fromServiceWorker());
      });
      const page = await applicationContext.newPage();
      await page.goto(origin);
      await page.evaluate(() => navigator.serviceWorker.ready);
      await page.reload();
      assert.equal(await page.locator("#legacy").count(), 1);
      assert.ok(await page.evaluate(() => navigator.serviceWorker.controller));
      for (let attempt = 0; attempt < 2; attempt += 1)
        assert.equal(await page.evaluate(async () => (await fetch('/icon.svg', { cache: 'force-cache' })).text()), oldIcon);
      assert.equal(legacyIconRequests, 1, 'The second bare-icon request must reuse the old year-long HTTP cache');
      migrated = true;
      // A browser update downloads the worker directly, even while the old worker serves its cached HTML.
      await page.evaluate(async () => {
        const registration = await navigator.serviceWorker.getRegistration();
        if (!registration) throw new Error("Legacy registration missing");
        await registration.update();
      });
      await page.getByTestId("text-input").waitFor();
      assert.equal(await page.locator("#legacy").count(), 0);
      await page.waitForFunction(async () => {
        const registrations = await navigator.serviceWorker.getRegistrations();
        return registrations.length === 1 && registrations[0].active?.scriptURL.endsWith('/studio-worker.js') && navigator.serviceWorker.controller?.scriptURL.endsWith('/studio-worker.js');
      });
      const remaining = await page.evaluate(async () => ({
        caches: await caches.keys(),
        api: (await (await caches.open("api-cache")).keys()).map((request) => request.url),
      }));
      assert.ok(!remaining.caches.includes(`workbox-precache-v2-${origin}/`));
      assert.ok(remaining.caches.includes(`workbox-precache-v2-${origin}/other/`));
      assert.ok(remaining.caches.includes("unrelated-user-cache"));
      assert.deepEqual(remaining.api, [`${origin}/other/api/keep`]);
      // The modern worker replaces the retired registration without registering either legacy name again.
      await page.reload();
      await page.getByTestId("text-input").waitFor();
      assert.deepEqual(await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).map((registration) => new URL(registration.active.scriptURL).pathname)), ['/studio-worker.js']);
      const iconUrls = await page.evaluate(async () => {
        const urls = [...document.querySelectorAll('link[rel="icon"],link[rel="apple-touch-icon"]')].map((link) => link.href);
        for (const manifest of ['/manifest.json', '/site.webmanifest'])
          for (const icon of (await (await fetch(manifest)).json()).icons)
            urls.push(new URL(icon.src, new URL(manifest, location.href)).href);
        return [...new Set(urls)];
      });
      assert.ok(iconUrls.length >= 4, 'HTML and both manifests must reference the versioned brand assets');
      for (const url of iconUrls) {
        assert.equal(new URL(url).origin, origin);
        assert.equal(new URL(url).searchParams.get('v'), iconVersion, 'Icon URLs must follow the actual brand SVG content hash');
      }
      const currentIcons = await iconBytes(page, iconUrls);
      for (const icon of currentIcons)
        assert.deepEqual(Buffer.from(icon.bytes), await fs.readFile(path.join(dist, new URL(icon.url).pathname)), `Versioned icon must contain the new canonical brand bytes: ${icon.url}`);
      const apiResult = await page.evaluate(async () => (await fetch('/api/generate_handwriting/task/old')).json());
      assert.equal(apiResult.source, 'network-only');
      await page.evaluate(() => {
        const install = new Event('beforeinstallprompt', { cancelable: true });
        Object.defineProperty(install, 'prompt', { value: async () => { document.documentElement.dataset.installPromptCalled = 'yes'; } });
        Object.defineProperty(install, 'userChoice', { value: Promise.resolve({ outcome: 'accepted' }) });
        window.dispatchEvent(install);
      });
      await page.getByTestId('pwa-install-btn').click();
      assert.equal(await page.locator('html').getAttribute('data-install-prompt-called'), 'yes');
      await page.getByTestId('pwa-install-btn').waitFor({ state: 'hidden' });
      const fontUrls = await wenKaiSources(page);
      assert.equal(fontUrls.length, 2, 'Both the UI subset and full WenKai font must be self-hosted');
      assert.ok(fontUrls.every((url) => new URL(url).origin === origin && new URL(url).pathname.endsWith('.woff2')));
      const onlineFaces = await loadWenKai(page);
      assert.equal(onlineFaces.length, 2, 'English/UI Chinese and subset-external 龘 must load both font faces');
      assert.ok(onlineFaces.every((face) => face.family === 'LXGW WenKai' && face.status === 'loaded'));
      await page.getByTestId('text-input').fill('离线草稿 $x^2$');
      await page.context().setOffline(true);
      offline = true;
      const fontRequestsBeforeOffline = networkFontRequests;
      await page.reload();
      await page.getByTestId('text-input').waitFor();
      await page.getByTestId('offline-notice').waitFor();
      assert.equal(await page.getByTestId('text-input').inputValue(), '离线草稿 $x^2$');
      await page.getByTestId('text-input').fill('离线仍可编辑 $x^2$');
      // The dynamically imported converter is a hashed build asset and must also work offline.
      await page.getByTestId('prepare-text-btn').click();
      await page.waitForFunction(() => document.querySelector('[data-testid="text-input"]').value.includes('x²'));
      const offlineApi = await page.evaluate(async () => {
        try { await fetch('/api/generate_handwriting/task/old'); return 'unexpected-success'; }
        catch { return 'network-failed'; }
      });
      assert.equal(offlineApi, 'network-failed');
      const apiPage = await page.context().newPage();
      await assert.rejects(apiPage.goto(`${origin}/api/generate_handwriting/task/old`));
      await apiPage.close();
      const cachedRequests = await page.evaluate(async () => {
        const result = [];
        for (const name of await caches.keys())
          if (name.startsWith('handwriting-studio-shell:')) result.push(...(await (await caches.open(name)).keys()).map((request) => request.url));
        return result;
      });
      assert.ok(cachedRequests.some((url) => /\/assets\/prepareHandwritingText-/.test(url)));
      for (const url of fontUrls) assert.ok(cachedRequests.includes(url), `${url} must be in the offline shell cache`);
      for (const url of iconUrls) assert.ok(cachedRequests.includes(url), `${url} must be in the offline shell cache`);
      assert.ok(cachedRequests.every((url) => !new URL(url).pathname.startsWith('/api/')));
      const cacheSession = await applicationContext.newCDPSession(page);
      await cacheSession.send('Network.clearBrowserCache');
      await cacheSession.detach();
      offlineFontResponses.clear();
      // This new Document owns a fresh FontFaceSet; cleared HTTP cache cannot rescue missing SW fonts.
      const fontPage = await applicationContext.newPage();
      const offlineSession = await applicationContext.newCDPSession(fontPage);
      try {
        await fontPage.goto(origin);
        await fontPage.getByTestId('text-input').waitFor();
        const offlineFaces = await loadWenKai(fontPage);
        assert.deepEqual(offlineFaces, onlineFaces);
        await expectOfflineCustomGlyphs(fontPage, offlineSession);
        assert.deepEqual(await iconBytes(fontPage, iconUrls), currentIcons, 'Versioned brand bytes must survive a fresh offline navigation');
        for (const url of iconUrls)
          assert.equal(offlineIconResponses.get(url), true, `${url} must be served by the service worker offline`);
        for (const url of fontUrls)
          assert.equal(offlineFontResponses.get(url), true, `${url} must be served by the service worker offline`);
        assert.equal(networkFontRequests, fontRequestsBeforeOffline, 'Offline fonts must not reach the HTTP server');
        assert.equal(await fontPage.evaluate(async () => {
          try { await fetch('/api/fonts_info'); return 'unexpected-network'; }
          catch { return 'network-failed'; }
        }), 'network-failed', 'The fresh font document must also have no API network access');
      } finally {
        await offlineSession.detach();
        await fontPage.close();
      }
      await page.context().setOffline(false);
      offline = false;
      await page.getByTestId('offline-notice').waitFor({ state: 'hidden' });
      // Both desktop detection paths must avoid a second installation layer.
      for (const desktopMode of ['bridge', 'user-agent']) {
        const context = await browser.newContext(desktopMode === 'user-agent' ? { userAgent: 'Handwriting Electron/42.0.0' } : {});
        if (desktopMode === 'bridge') await context.addInitScript(() => {
          window.handwritingDesktop = { onDownloadFinished() {}, revealLastDownload() {} };
        });
        const desktopPage = await context.newPage();
        await desktopPage.goto(origin);
        await desktopPage.getByTestId('text-input').waitFor();
        await desktopPage.waitForLoadState('networkidle');
        assert.equal(await desktopPage.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length), 0);
        await desktopPage.evaluate(() => {
          const install = new Event('beforeinstallprompt', { cancelable: true });
          Object.defineProperty(install, 'prompt', { value: async () => undefined });
          Object.defineProperty(install, 'userChoice', { value: Promise.resolve({ outcome: 'accepted' }) });
          window.dispatchEvent(install);
        });
        assert.equal(await desktopPage.getByTestId('pwa-install-btn').count(), 0);
        await context.close();
      }
    } finally {
      await browser?.close();
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  });
}
