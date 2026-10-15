export {};
declare const self: ServiceWorkerGlobalScope;
const worker = self;

worker.addEventListener('install', (event) => {
  event.waitUntil(worker.skipWaiting());
});

async function retireLegacyWorker(): Promise<void> {
  const scope = worker.registration.scope;
  const apiPrefix = new URL('api/', scope).href;
  for (const name of await caches.keys()) {
    if (name.startsWith('workbox-precache-') && name.endsWith(scope)) {
      await caches.delete(name);
    } else if (name === 'api-cache') {
      const cache = await caches.open(name);
      for (const request of await cache.keys()) {
        if (request.url.startsWith(apiPrefix)) await cache.delete(request);
      }
      if ((await cache.keys()).length === 0) await caches.delete(name);
    }
  }
  await worker.clients.claim();
  const clients = await worker.clients.matchAll({ type: 'window' });
  await worker.registration.unregister();
  await Promise.all(
    clients
      .filter((client) => client.url.startsWith(scope))
      .map((client) => client.navigate(client.url)),
  );
}

worker.addEventListener('activate', (event) => {
  event.waitUntil(retireLegacyWorker());
});
