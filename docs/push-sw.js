/* PULSE push handlers, imported into the generated service worker (vite.config.ts).
   A notification shows who it is from and "New Chat" / "New Snap" — the server never
   sends message text. Tapping it opens (or focuses) PULSE at that chat.
   Paths are resolved against the worker's scope, so PULSE also works from a sub-folder
   (e.g. GitHub Pages: https://name.github.io/repo/). */
const inScope = (path) => new URL(String(path).replace(/^\/+/, ''), self.registration.scope).href;
self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch { d = {}; }
  const url = typeof d.url === 'string' && d.url.startsWith('/') && !d.url.startsWith('//') ? d.url : '/';
  event.waitUntil(self.registration.showNotification(typeof d.title === 'string' && d.title ? d.title : 'PULSE', {
    body: typeof d.body === 'string' ? d.body : 'New activity',
    tag: typeof d.tag === 'string' && d.tag ? d.tag : 'pulse',
    renotify: true,
    icon: inScope('icon-192.png'),
    badge: inScope('icon-192.png'),
    data: { url },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL(inScope((event.notification.data && event.notification.data.url) || '/'));
  if (target.origin !== self.location.origin || !target.href.startsWith(self.registration.scope)) return;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of windows) {
      if ('focus' in w) {
        try { await w.navigate(target.href); } catch { /* not controlled yet */ }
        return w.focus();
      }
    }
    return self.clients.openWindow(target.href);
  })());
});
