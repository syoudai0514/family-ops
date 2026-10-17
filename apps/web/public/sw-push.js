// Imported by the service worker: shows pushed reminders and opens the app on tap.
self.addEventListener('push', (event) => {
  let message = {};
  try {
    message = event.data ? event.data.json() : {};
  } catch {
    message = { body: event.data ? event.data.text() : '' };
  }
  const title = message.title || 'おうちノート';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: message.body || '',
      tag: message.tag || undefined,
      icon: '/pwa-192.png',
      badge: '/pwa-192.png',
      data: { url: typeof message.url === 'string' && message.url.startsWith('/') ? message.url : '/' },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      const open = windows.find((client) => new URL(client.url).origin === self.location.origin);
      if (open) return open.focus().then((client) => client.navigate(target));
      return self.clients.openWindow(target);
    }),
  );
});
