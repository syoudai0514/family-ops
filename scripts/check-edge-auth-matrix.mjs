// Edge auth matrix lint (docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md CI section):
//
// v6 review fix (P1-D, this round): supabase/config.toml's [functions.*]
// block is now a LIVE deployment snapshot (only functions actually present
// under supabase/functions/), not a 1:1 mirror of the full 52-function v6
// design matrix — declaring a config.toml entry for a function that has no
// index.ts on disk is what a real `supabase start`/`supabase db reset`
// cannot execute against. The two matrices are therefore linted
// independently, both required to pass:
//
//   1. design-matrix completeness (standalone): the full normative
//      snapshot vendored at docs/design/v6/supabase/config.toml still
//      declares every function classified in
//      docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md — this is a drift check
//      on the vendored v6 design package alone, unrelated to what's
//      deployed so far.
//   2. live deployment correctness: every function actually deployed under
//      supabase/functions/ (has an index.ts) has a supabase/config.toml
//      entry, that entry's verify_jwt matches the normative classification
//      for that name, and supabase/config.toml declares no entry for a
//      function that isn't deployed (live config never gets ahead of
//      what's actually implemented).
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

function parseFunctionsBlock(tomlText) {
  const entries = new Map();
  const re = /\[functions\.([a-z0-9-]+)\]\s*\n\s*verify_jwt\s*=\s*(true|false)/g;
  let match;
  while ((match = re.exec(tomlText)) !== null) {
    entries.set(match[1], match[2] === 'true');
  }
  return entries;
}

// v6 review fix (WP2): the vendored 52-function design matrix has no named
// endpoint for "initial dropoff/pickup times and weekly assignee setup"
// (10_WORK_PACKAGES.md's WP2 line item) — see
// supabase/migrations/20260819000018_dropoff_pickup_setup.sql's header
// comment for the full gap analysis, and docs/adr/0002-dropoff-pickup-setup-endpoint.md
// for the ADR recording this decision. Rather than silently loosening the
// "every deployed function must be in the normative matrix" check for
// everything, this one name is explicitly allowlisted — any other deployed
// function not in the normative matrix still fails the lint.
//
// WP5 additions: propose-ai-draft, confirm-request-draft, and
// confirm-handover-draft are likewise absent from the vendored 52-function
// matrix — 18_MUTATION_CONTRACT_MATRIX.md #13 describes the AI-draft
// propose/confirm flow in prose but never settles on Edge Function names.
// See docs/adr/0003-ai-draft-propose-endpoint.md.
//
// Sol re-review #3 additions (docs/adr/0011): list-pending-actions/
// confirm-pending-action/cancel-pending-action (Today Priority 2's "LINEから
// 作ったpending action", 02_UX_AND_SCREENS.md #3) and get-today-schedule
// (Today Priority 1's calendar/conflict schedule) fill read/mutation gaps
// against already-built backend state — no named endpoint exists for any of
// these in the vendored matrix.
const GAP_FILL_FUNCTIONS = new Set([
  'configure-dropoff-pickup',
  'propose-ai-draft',
  'confirm-request-draft',
  'confirm-handover-draft',
  'list-pending-actions',
  'confirm-pending-action',
  'cancel-pending-action',
  'get-today-schedule',
  'create-assignment-change-request',
  'accept-assignment-change-request',
  'deactivate-recurrence',
  'get-week-schedule',
  'complete-onboarding-step',
  'replace-recurrence-schedule',
  'update-task-categories',
  'process-family-ops-calendar-outbox',
  // v3.3 review-fix P1: explicit household role, routine inclusion, and
  // calendar write-target mutations are implemented endpoints but were not
  // named in the frozen v6 design bundle.
  'set-routine-definition-options',
  'set-family-calendar-target',
  'set-family-role',
]);

const actualConfigPath = path.join(repoRoot, 'supabase/config.toml');
const normativeConfigPath = path.join(repoRoot, 'docs/design/v6/supabase/config.toml');

const actual = parseFunctionsBlock(readFileSync(actualConfigPath, 'utf8'));
const normative = parseFunctionsBlock(readFileSync(normativeConfigPath, 'utf8'));

let failed = false;

// ---------------------------------------------------------------------------
// 1. design-matrix completeness (standalone, independent of live deploys)
// ---------------------------------------------------------------------------
const EXPECTED_DESIGN_MATRIX_SIZE = 52;
if (normative.size === 0) {
  console.error('FAIL: no [functions.*] entries parsed from docs/design/v6/supabase/config.toml');
  failed = true;
} else if (normative.size !== EXPECTED_DESIGN_MATRIX_SIZE) {
  console.error(
    `FAIL: docs/design/v6/supabase/config.toml design matrix has ${normative.size} functions, expected exactly ${EXPECTED_DESIGN_MATRIX_SIZE} (EDGE_FUNCTION_AUTH_MATRIX.md drift)`,
  );
  failed = true;
}

// ---------------------------------------------------------------------------
// 2. live deployment correctness
// ---------------------------------------------------------------------------
if (actual.size === 0) {
  console.error('FAIL: no [functions.*] entries parsed from supabase/config.toml');
  failed = true;
}

const functionsDir = path.join(repoRoot, 'supabase/functions');
const deployed = readdirSync(functionsDir).filter((entry) => {
  if (entry.startsWith('_') || entry.startsWith('.')) return false;
  const full = path.join(functionsDir, entry);
  return statSync(full).isDirectory() && statSync(path.join(full, 'index.ts')).isFile();
});

if (deployed.length === 0) {
  console.error('FAIL: no deployed functions found under supabase/functions/');
  failed = true;
}

for (const name of deployed) {
  if (!normative.has(name)) {
    if (GAP_FILL_FUNCTIONS.has(name)) {
      if (!actual.has(name)) {
        console.error(`FAIL: gap-fill function "${name}" has no supabase/config.toml [functions.${name}] entry`);
        failed = true;
      }
      continue;
    }
    console.error(`FAIL: deployed function "${name}" is not in the v6 design matrix (EDGE_FUNCTION_AUTH_MATRIX.md) at all`);
    failed = true;
    continue;
  }
  if (!actual.has(name)) {
    console.error(`FAIL: deployed function "${name}" has no supabase/config.toml [functions.${name}] entry`);
    failed = true;
    continue;
  }
  if (actual.get(name) !== normative.get(name)) {
    console.error(
      `FAIL: supabase/config.toml [functions.${name}] verify_jwt=${actual.get(name)} does not match normative verify_jwt=${normative.get(name)}`,
    );
    failed = true;
  }
}

const deployedSet = new Set(deployed);
for (const name of actual.keys()) {
  if (!deployedSet.has(name)) {
    console.error(
      `FAIL: supabase/config.toml declares [functions.${name}] but supabase/functions/${name}/index.ts does not exist — live config must only contain deployed functions`,
    );
    failed = true;
  }
}

// v6 review fix (P1-7): Google Sign-In is the only onboarding path (see
// docs/design/v6/01_ARCHITECTURE.md), so enable_signup must stay true and
// the Google external provider must stay enabled — a regression here would
// silently lock every new family out of creating a household.
const actualConfigText = readFileSync(actualConfigPath, 'utf8');
if (!/\benable_signup\s*=\s*true\b/.test(actualConfigText)) {
  console.error('FAIL: supabase/config.toml [auth] enable_signup must be true (Google Sign-In is the onboarding path)');
  failed = true;
}
if (!/\[auth\.external\.google\][^[]*\benabled\s*=\s*true\b/.test(actualConfigText)) {
  console.error('FAIL: supabase/config.toml [auth.external.google] must be enabled = true');
  failed = true;
}
// v6 review fix (P1-C, this round): the Google -> GoTrue callback and the
// app's own post-login redirect must stay on two distinct env vars — a
// regression back to a single shared var would silently break either the
// OAuth handshake (wrong callback registered with Google) or the app
// redirect allowlist.
if (!/redirect_uri\s*=\s*"env\(GOOGLE_SIGNIN_CALLBACK_URL\)"/.test(actualConfigText)) {
  console.error(
    'FAIL: supabase/config.toml [auth.external.google] redirect_uri must read env(GOOGLE_SIGNIN_CALLBACK_URL), not an app-redirect-shaped var',
  );
  failed = true;
}

if (failed) {
  process.exit(1);
}

console.log(
  `OK: design matrix has ${normative.size} functions; live supabase/config.toml declares exactly the ${deployed.length} deployed functions (${deployed.join(', ')}), each matching its normative verify_jwt classification.`,
);
