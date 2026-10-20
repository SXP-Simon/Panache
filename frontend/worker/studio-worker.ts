export {};
declare const self: ServiceWorkerGlobalScope;
declare const __STUDIO_PRECACHE_PATHS__: readonly string[];
declare const __STUDIO_CACHE_VERSION__: string;

const worker = self;
const scope = worker.registration.scope;
const cachePrefix = `handwriting-studio-shell:${scope}:`;
const cacheName = `${cachePrefix}${__STUDIO_CACHE_VERSION__}`;
const shellUrls = new Set(__STUDIO_PRECACHE_PATHS__.map((path) => new URL(path, scope).href));
const indexUrl = new URL('index.html', scope).href;
const apiPrefix = new URL('api/', scope).pathname;

worker.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(cacheName);
      await cache.addAll(Array.from(shellUrls, (url) => new Request(url, { cache: 'reload' })));
    })(),
  );
});

worker.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const name of await caches.keys())
        if (name.startsWith(cachePrefix) && name !== cacheName) await caches.delete(name);
      await worker.clients.claim();
    })(),
  );
});

async function navigation(request: Request): Promise<Response> {
  try {
    return await fetch(request);
  } catch {
    const cached = await (await caches.open(cacheName)).match(indexUrl);
    return cached ?? Response.error();
  }
}

async function shellAsset(request: Request): Promise<Response> {
  return (await (await caches.open(cacheName)).match(request)) ?? fetch(request);
}

worker.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (
    request.method !== 'GET' ||
    url.origin !== worker.location.origin ||
    !url.href.startsWith(scope) ||
    url.pathname.startsWith(apiPrefix) ||
    url.pathname === apiPrefix.slice(0, -1)
  )
    return;
  if (request.mode === 'navigate') event.respondWith(navigation(request));
  else if (shellUrls.has(url.href)) event.respondWith(shellAsset(request));
});

worker.addEventListener('message', (event) => {
  if (event.data === 'PANACHE_ACTIVATE_UPDATE') void worker.skipWaiting();
});
