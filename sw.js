/* Service worker minimale: rende l'app installabile e usabile offline.
   Strategia "prima la rete": quando c'è connessione mostra sempre l'ultima
   versione pubblicata; se manca la connessione, usa l'ultima copia salvata. */
const CACHE_NAME = 'tabella-esercizi-v17';
const APP_SHELL = [
  './', './index.html', './scheda.html', './libreria.html', './impostazioni.html',
  './exercises-data.js', './manifest.json',
  './icon-192.png', './icon-512.png', './icon-192-maskable.png', './icon-512-maskable.png',
  './apple-touch-icon.png', './logo.png', './primary-card-bg.jpg', './libreria-card-bg.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // richieste verso Supabase (o altri domini) non vengono mai messe in cache: solo l'app shell locale
  if (url.origin !== self.location.origin || event.request.method !== 'GET') return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const clone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
