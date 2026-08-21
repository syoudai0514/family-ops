// This file is imported by each newly installed service worker. It is
// intentionally limited to app-shell recovery: no storage, IndexedDB, or
// Supabase session data is read or deleted.
self.addEventListener('activate', (event) => {
  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((windows) =>
        Promise.all(
          windows.map((client) => client.navigate(client.url).catch(() => undefined)),
        ),
      ),
  );
});
