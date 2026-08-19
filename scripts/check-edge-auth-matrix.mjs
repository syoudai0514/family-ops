// Edge auth matrix lint (docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md CI section):
//   - every entry in supabase/config.toml matches the normative snapshot
//     vendored at docs/design/v6/supabase/config.toml exactly (name + verify_jwt)
//   - every function actually deployed under supabase/functions/ has a
//     config.toml entry, and that entry's verify_jwt matches the normative
//     classification (no unknown/undeclared function is deployed)
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

const actualConfigPath = path.join(repoRoot, 'supabase/config.toml');
const normativeConfigPath = path.join(repoRoot, 'docs/design/v6/supabase/config.toml');

const actual = parseFunctionsBlock(readFileSync(actualConfigPath, 'utf8'));
const normative = parseFunctionsBlock(readFileSync(normativeConfigPath, 'utf8'));

if (actual.size === 0) {
  console.error('FAIL: no [functions.*] entries parsed from supabase/config.toml');
  process.exit(1);
}
if (normative.size === 0) {
  console.error('FAIL: no [functions.*] entries parsed from docs/design/v6/supabase/config.toml');
  process.exit(1);
}

let failed = false;

for (const [name, verifyJwt] of actual) {
  if (!normative.has(name)) {
    console.error(`FAIL: supabase/config.toml declares unknown function "${name}" (not in EDGE_FUNCTION_AUTH_MATRIX.md)`);
    failed = true;
    continue;
  }
  if (normative.get(name) !== verifyJwt) {
    console.error(
      `FAIL: supabase/config.toml [functions.${name}] verify_jwt=${verifyJwt} does not match normative verify_jwt=${normative.get(name)}`,
    );
    failed = true;
  }
}

for (const [name, verifyJwt] of normative) {
  if (!actual.has(name)) {
    console.error(`FAIL: supabase/config.toml is missing normative function "${name}" (verify_jwt=${verifyJwt})`);
    failed = true;
  }
}

// Every deployed function (a directory with an index.ts) must have a
// config.toml entry with the correct classification.
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
    console.error(`FAIL: deployed function "${name}" has no supabase/config.toml [functions.${name}] entry`);
    failed = true;
  }
}

if (failed) {
  process.exit(1);
}

console.log(
  `OK: ${actual.size} config.toml entries match the normative EDGE_FUNCTION_AUTH_MATRIX.md snapshot exactly; ` +
    `all ${deployed.length} deployed functions (${deployed.join(', ')}) are classified.`,
);
