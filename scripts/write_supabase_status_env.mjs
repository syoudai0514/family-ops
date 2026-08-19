// v6 review fix (P1-D): `supabase status -o env >> "$GITHUB_ENV"` was
// appended raw — the CLI's `-o env` output wraps every value in double
// quotes (`API_URL="http://127.0.0.1:54321"`), so the quote characters
// became part of the value in every later step's environment. Rather than
// regex-stripping the outer quotes back off `-o env` output (fragile if the
// CLI ever changes its quoting), this reads the CLI's machine-readable
// `-o json` output instead and writes clean, unquoted values into
// $GITHUB_ENV.
//
// Usage: supabase status -o json | node scripts/write_supabase_status_env.mjs
import { randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';

const githubEnvPath = process.env.GITHUB_ENV;
if (!githubEnvPath) {
  console.error('FAIL: $GITHUB_ENV is not set (this script only makes sense inside a GitHub Actions step)');
  process.exit(1);
}

let raw;
try {
  raw = readFileSync(0, 'utf8');
} catch {
  console.error('FAIL: could not read supabase status -o json output from stdin');
  process.exit(1);
}

let status;
try {
  status = JSON.parse(raw);
} catch (err) {
  console.error(`FAIL: supabase status -o json did not produce valid JSON: ${err.message}`);
  console.error(raw);
  process.exit(1);
}

if (typeof status !== 'object' || status === null || Array.isArray(status)) {
  console.error('FAIL: supabase status -o json did not produce a flat object');
  process.exit(1);
}

const written = [];
for (const [key, value] of Object.entries(status)) {
  if (value === null || value === undefined) continue;
  const delimiter = `GHENV_${randomUUID().replace(/-/g, '')}`;
  appendFileSync(githubEnvPath, `${key}<<${delimiter}\n${String(value)}\n${delimiter}\n`);
  written.push(key);
}

if (written.length === 0) {
  console.error('FAIL: supabase status -o json produced zero fields to export');
  process.exit(1);
}

console.log(`OK: wrote ${written.length} clean (unquoted) env vars to $GITHUB_ENV: ${written.join(', ')}`);
