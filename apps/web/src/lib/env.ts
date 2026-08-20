// Typed, validated access to build-time environment variables.
// Fails fast at startup rather than surfacing confusing runtime errors later.
// Variable names follow docs/design/v6/ENV_TEMPLATE.md exactly.

interface AppEnv {
  supabaseUrl: string;
  supabasePublishableKey: string;
  appName: string;
}

function readEnv(): AppEnv {
  const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
  const supabasePublishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
  const appName = import.meta.env.VITE_APP_NAME ?? 'Family Ops';

  const missing: string[] = [];
  if (!supabaseUrl) missing.push('VITE_SUPABASE_URL');
  if (!supabasePublishableKey) missing.push('VITE_SUPABASE_PUBLISHABLE_KEY');

  if (missing.length > 0) {
    throw new Error(
      `Missing required environment variables: ${missing.join(', ')}. ` +
        'Copy apps/web/.env.example to apps/web/.env.local and fill in values.',
    );
  }

  return { supabaseUrl, supabasePublishableKey, appName };
}

let cached: AppEnv | null = null;

export function getAppEnv(): AppEnv {
  if (!cached) {
    cached = readEnv();
  }
  return cached;
}
