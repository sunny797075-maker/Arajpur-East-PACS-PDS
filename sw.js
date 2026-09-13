/* Cache only bundled app assets. Device records never pass through this worker. */
'use strict';
const ROOT = self.registration.scope;
const CACHE = `pds-shell-v1:${ROOT}`;
const ASSETS = ['index.html', 'css/style.css', 'js/storage.js', 'js/tracker.js', 'js/app.js'].map(path => new URL(path, ROOT).href);
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(ASSETS.map(url => new Request(url, { cache: 'reload' })))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(self.clients.claim());
});
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  const navigation = event.request.mode === 'navigate' && (url.href === ROOT || url.pathname === new URL('index.html', ROOT).pathname);
  if (!navigation && !ASSETS.includes(url.href)) return;
  const key = navigation ? ASSETS[0] : url.href;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const response = await fetch(event.request);
      if (response.ok) await cache.put(key, response.clone());
      return response;
    } catch (error) {
      const cached = await cache.match(key);
      if (cached) return cached;
      throw error;
    }
  })());
});
