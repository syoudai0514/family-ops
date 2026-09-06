// Edge auth matrix lint. The frozen v6 design matrix remains an independent
// 52-function contract; later accepted/canonical gap-fill endpoints are
// explicitly allowlisted without weakening live/deployed consistency checks.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

function parseFunctionsBlock(tomlText) {
  const entries = new Map();
  const re = /\[functions\.([a-z0-9-]+)\]\s*\n\s*verify_jwt\s*=\s*(true|false)/g;
  let match;
  while ((match = re.exec(tomlText)) !== null) entries.set(match[1], match[2] === 'true');
  return entries;
}

const GAP_FILL_FUNCTIONS = new Set([
  'configure-dropoff-pickup',
  'propose-ai-draft',
  // Issue #54 PWA Concierge proposal surface. Authenticated and read-only with
  // respect to business objects; it reuses the reviewed LINE semantic parser.
  'propose-concierge-candidates',
  'confirm-request-draft',
  'confirm-handover-draft',
  'propose-event-plan',
  'confirm-event-plan',
  'list-pending-actions',
  'confirm-pending-action',
  'cancel-pending-action',
  'update-pending-action',
  'get-today-schedule',
  'create-assignment-change-request',
  'accept-assignment-change-request',
  'deactivate-recurrence',
  'get-week-schedule',
  'complete-onboarding-step',
  'replace-recurrence-schedule',
  'update-task-categories',
  'update-household-terminology',
  'process-family-ops-calendar-outbox',
  'set-routine-definition-options',
  'replace-routine-subtasks',
  'set-family-calendar-target',
  'set-family-role',
  'start-request-followup',
  'claim-shopping-item',
  'reopen-shopping-item',
  'test-simulation',
  'get-current-routine-sessions',
  'reconcile-routine-session',
  'respond-request',
  'negotiate-request',
  'set-task-waiting',
  'correct-task-actual',
  'change-task-assignment',
  'add-task-completion-evidence',
  // Q89-Q106 authenticated nursery review surfaces + worker-token processor.
  'get-nursery-review',
  'list-nursery-reviews',
  'resolve-nursery-ambiguity',
  'confirm-nursery-review',
  'delete-nursery-source-image',
  'process-nursery-image-intake',
  // Q110-Q112 authenticated Google inbound diff/duplicate review surfaces.
  'list-google-event-reviews',
  'resolve-google-event-review',
  // Issue #48 final UX: period-scoped weekly transport template + occurrence override.
  'transport-schedule',
]);

const actualConfigPath = path.join(repoRoot, 'supabase/config.toml');
const normativeConfigPath = path.join(repoRoot, 'docs/design/v6/supabase/config.toml');
const actualConfigText = readFileSync(actualConfigPath, 'utf8');
const actual = parseFunctionsBlock(actualConfigText);
const normative = parseFunctionsBlock(readFileSync(normativeConfigPath, 'utf8'));
let failed = false;

const EXPECTED_DESIGN_MATRIX_SIZE = 52;
if (normative.size === 0) {
  console.error('FAIL: no [functions.*] entries parsed from docs/design/v6/supabase/config.toml');
  failed = true;
} else if (normative.size !== EXPECTED_DESIGN_MATRIX_SIZE) {
  console.error(`FAIL: frozen design matrix has ${normative.size} functions, expected ${EXPECTED_DESIGN_MATRIX_SIZE}`);
  failed = true;
}
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
  if (!actual.has(name)) {
    console.error(`FAIL: deployed function "${name}" has no live config entry`);
    failed = true;
    continue;
  }
  if (normative.has(name)) {
    if (actual.get(name) !== normative.get(name)) {
      console.error(`FAIL: ${name} verify_jwt=${actual.get(name)} does not match normative ${normative.get(name)}`);
      failed = true;
    }
  } else if (!GAP_FILL_FUNCTIONS.has(name)) {
    console.error(`FAIL: deployed function "${name}" is absent from frozen matrix and reviewed gap-fill allowlist`);
    failed = true;
  }
}

const deployedSet = new Set(deployed);
for (const name of actual.keys()) {
  if (!deployedSet.has(name)) {
    console.error(`FAIL: live config declares undeployed function "${name}"`);
    failed = true;
  }
}

if (!/\benable_signup\s*=\s*true\b/.test(actualConfigText)) {
  console.error('FAIL: enable_signup must stay true for Google Sign-In onboarding');
  failed = true;
}
if (!/\[auth\.external\.google\][^[]*\benabled\s*=\s*true\b/.test(actualConfigText)) {
  console.error('FAIL: Google Auth must stay enabled');
  failed = true;
}
if (!/redirect_uri\s*=\s*"env\(GOOGLE_SIGNIN_CALLBACK_URL\)"/.test(actualConfigText)) {
  console.error('FAIL: Google callback must use env(GOOGLE_SIGNIN_CALLBACK_URL)');
  failed = true;
}

if (failed) process.exit(1);
console.log(`OK: frozen=${normative.size}; live/deployed=${deployed.length}; strict auth/config consistency preserved.`);
