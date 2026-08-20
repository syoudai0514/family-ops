import { createClient } from '@supabase/supabase-js';
import { getAppEnv } from './env';

// Client-side Supabase handle. This client is intentionally limited to:
// - SELECT on RLS-safe public tables
// - auth (sign-in/out)
// All state mutations go through Edge Functions, never supabase.rpc('server_tx_*')
// or direct table writes — see docs/design/v6/04_SECURITY_RLS_PRIVACY.md.
export function createSupabaseClient() {
  const { supabaseUrl, supabasePublishableKey } = getAppEnv();
  return createClient(supabaseUrl, supabasePublishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
    },
  });
}

export const supabase = createSupabaseClient();
