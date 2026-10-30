// Closet Mapper service worker: lets the app open and work with no signal (closets often have none).
// The page itself is fetched fresh whenever there is a connection, so updates still arrive straight away.
const V = 'cm-4.0.9';
const SHELL = ['./', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png', './favicon-32.png'];
const LIBS = /^https:\/\/(cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|unpkg\.com|fonts\.googleapis\.com|fonts\.gstatic\.com)\//;

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

function timeout(ms) { return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms)); }

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.origin === location.origin) {
    if (r.mode === 'navigate' || u.pathname.endsWith('/') || u.pathname.endsWith('.html')) {
      // the app: network first (5 s on weak Wi-Fi), else the copy from last time
      e.respondWith(Promise.race([fetch(r), timeout(5000)]).then(res => {
        if (res && res.ok) { const copy = res.clone(); caches.open(V).then(c => c.put('./', copy)); }
        return res;
      }).catch(() => caches.match('./').then(m => m || caches.match(r))));
      return;
    }
    if (u.pathname.endsWith('sw.js')) return;
    e.respondWith(caches.match(r).then(m => m || fetch(r).then(res => {
      if (res && res.ok) { const copy = res.clone(); caches.open(V).then(c => c.put(r, copy)); }
      return res;
    })));
    return;
  }
  if (LIBS.test(r.url)) {
    // libraries and fonts: versioned URLs, so the cached copy is fine; refresh it in the background
    e.respondWith(caches.open(V).then(c => c.match(r).then(m => {
      const net = fetch(r).then(res => { if (res && (res.ok || res.type === 'opaque')) c.put(r, res.clone()); return res; }).catch(() => m);
      return m || net;
    })));
  }
  // everything else (the Supabase account service) goes straight to the network
});
