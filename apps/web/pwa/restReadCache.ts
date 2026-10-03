// Workbox serializes this callback into the generated service worker. Keep it
// self-contained: imported helpers and module constants are unavailable there.
export async function restReadCacheKey({ request }: { request: Request }): Promise<string> {
  const credentials = JSON.stringify([
    request.headers.get('Authorization'),
    request.headers.get('apikey'),
  ]);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(credentials));
  const fingerprint = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');
  const cacheUrl = new URL(request.url);
  cacheUrl.searchParams.set('__family_ops_credentials', fingerprint);
  // Return a URL instead of copying the Request, so bearer credentials are
  // neither stored in cache keys nor sent as a query parameter to the server.
  return cacheUrl.href;
}
