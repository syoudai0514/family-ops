import { describe, expect, it } from 'vitest';
import { getAppEnv } from './env';

describe('getAppEnv', () => {
  it('returns the configured Supabase URL and anon key', () => {
    const env = getAppEnv();
    expect(env.supabaseUrl).toBe('http://localhost:54321');
    expect(env.supabasePublishableKey).toBe('test-publishable-key');
  });
});
