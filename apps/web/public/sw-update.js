// Imported by each new service worker to refresh the iOS/Android app shell
// and discard the former REST cache
// whose URL-only keys could serve another account's data. Supabase sessions
// and local app state remain untouched.
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.delete('supabase-rest-reads').then(() =>
      self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
        // A claimed window's navigation can wait for this worker to finish
        // activating. Dispatch it without waiting for navigation itself.
        for (const client of windows) {
          void client.navigate(client.url).catch(() => undefined);
        }
      }),
    ),
  );
});
