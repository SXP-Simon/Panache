"use strict";

const assert = require("node:assert/strict");
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
};

for (const script of ["service-worker.js", "sw.js"]) {
  test(`cached legacy ${script} upgrades without running the React entry point`, { timeout: 45_000 }, async () => {
    let migrated = false;
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
        const pathname = new URL(request.url ?? "/", "http://localhost").pathname;
        response.setHeader("Cache-Control", "no-store");
        if (pathname === `/${script}` && !migrated) {
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
      const page = await applicationContext.newPage();
      await page.goto(origin);
      await page.evaluate(() => navigator.serviceWorker.ready);
      await page.reload();
      assert.equal(await page.locator("#legacy").count(), 1);
      assert.ok(await page.evaluate(() => navigator.serviceWorker.controller));
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
      await page.getByTestId('text-input').fill('离线草稿 $x^2$');
      await page.context().setOffline(true);
      await page.reload();
      await page.getByTestId('text-input').waitFor();
      await page.getByTestId('offline-notice').waitFor();
      assert.equal(await page.getByTestId('text-input').inputValue(), '离线草稿 $x^2$');
      await page.getByTestId('text-input').fill('离线仍可编辑 $x^2$');
      // The dynamically imported converter is a hashed build asset and must also work offline.
      await page.getByTestId('convert-latex-btn').click();
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
      assert.ok(cachedRequests.some((url) => /\/assets\/latexToUnicode-/.test(url)));
      assert.ok(cachedRequests.every((url) => !new URL(url).pathname.startsWith('/api/')));
      await page.context().setOffline(false);
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
