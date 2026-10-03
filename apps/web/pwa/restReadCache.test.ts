// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { restReadCacheKey } from './restReadCache';

const url = 'https://example.supabase.co/rest/v1/tasks?select=*&household_id=eq.family';

function readRequest(token?: string, apiKey = 'publishable-key') {
  return new Request(url, {
    headers: { apikey: apiKey, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
}

describe('authenticated offline REST cache', () => {
  it('never serves a prior account response to another account or an anonymous read', async () => {
    const first = await restReadCacheKey({ request: readRequest('parent-a-token') });
    const second = await restReadCacheKey({ request: readRequest('parent-b-token') });
    const anonymous = await restReadCacheKey({ request: readRequest() });
    const cache = new Map([[first, { title: 'Private family task' }]]);

    expect(cache.get(await restReadCacheKey({ request: readRequest('parent-a-token') }))).toEqual({
      title: 'Private family task',
    });
    expect(cache.get(second)).toBeUndefined();
    expect(cache.get(anonymous)).toBeUndefined();
  });

  it('isolates refreshed credentials and API keys without persisting bearer tokens', async () => {
    const request = readRequest('secret-token');
    const key = await restReadCacheKey({ request });
    expect(key).not.toContain('secret-token');
    expect(key).not.toContain('publishable-key');
    expect(key).not.toBe(await restReadCacheKey({ request: readRequest('refreshed-token') }));
    expect(key).not.toBe(
      await restReadCacheKey({ request: readRequest('secret-token', 'other-key') }),
    );
    expect(request.url).toBe(url);
    expect(new URL(key).searchParams.get('select')).toBe('*');
    expect(new URL(key).searchParams.get('__family_ops_credentials')).toMatch(/^[a-f0-9]{64}$/);
  });

  it('remains self-contained when serialized into the production service worker', async () => {
    const serialized = new Function(
      `return (${restReadCacheKey.toString()});`,
    )() as typeof restReadCacheKey;
    const request = readRequest('parent-a-token');
    expect(await serialized({ request })).toBe(await restReadCacheKey({ request }));
  });
});
