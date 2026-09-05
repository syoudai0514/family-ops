// Live Edge auth/config drift lint. The frozen v6 matrix stays an independent
// 52-function contract; explicitly reviewed gap-fill endpoints are allowlisted.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
function parseFunctionsBlock(text) {
  const entries = new Map();
  const re = /\[functions\.([a-z0-9-]+)\]\s*\n\s*verify_jwt\s*=\s*(true|false)/g;
  let m; while ((m = re.exec(text)) !== null) entries.set(m[1], m[2] === 'true');
  return entries;
}
const GAP_FILL_FUNCTIONS = new Set([
  'configure-dropoff-pickup','propose-ai-draft','confirm-request-draft','confirm-handover-draft',
  'propose-event-plan','confirm-event-plan','list-pending-actions','confirm-pending-action',
  'cancel-pending-action','update-pending-action','get-today-schedule','create-assignment-change-request',
  'accept-assignment-change-request','deactivate-recurrence','get-week-schedule','complete-onboarding-step',
  'replace-recurrence-schedule','update-task-categories','update-household-terminology',
  'process-family-ops-calendar-outbox','set-routine-definition-options','replace-routine-subtasks',
  'set-family-calendar-target','set-family-role','start-request-followup','claim-shopping-item','reopen-shopping-item',
  'test-simulation','get-current-routine-sessions','reconcile-routine-session','respond-request','negotiate-request',
  'set-task-waiting','correct-task-actual','change-task-assignment','add-task-completion-evidence',
  // Q89-Q106: JWT-authenticated review/list/resolve/confirm/delete and worker-token image processor.
  'get-nursery-review','list-nursery-reviews','resolve-nursery-ambiguity','confirm-nursery-review',
  'delete-nursery-source-image','process-nursery-image-intake',
]);
const actualPath = path.join(repoRoot,'supabase/config.toml');
const normativePath = path.join(repoRoot,'docs/design/v6/supabase/config.toml');
const actualText = readFileSync(actualPath,'utf8');
const actual = parseFunctionsBlock(actualText);
const normative = parseFunctionsBlock(readFileSync(normativePath,'utf8'));
let failed=false;
if (normative.size !== 52) { console.error(`FAIL: frozen design matrix has ${normative.size}, expected 52`); failed=true; }
const functionsDir=path.join(repoRoot,'supabase/functions');
const deployed=readdirSync(functionsDir).filter((entry)=>{
  if(entry.startsWith('_')||entry.startsWith('.')) return false;
  const full=path.join(functionsDir,entry);
  return statSync(full).isDirectory() && statSync(path.join(full,'index.ts')).isFile();
});
for(const name of deployed){
  if(!actual.has(name)){ console.error(`FAIL: deployed ${name} missing live config`); failed=true; continue; }
  if(normative.has(name)){
    if(actual.get(name)!==normative.get(name)){ console.error(`FAIL: ${name} verify_jwt drift`); failed=true; }
  } else if(!GAP_FILL_FUNCTIONS.has(name)) { console.error(`FAIL: ${name} absent from frozen matrix and gap-fill allowlist`); failed=true; }
}
const deployedSet=new Set(deployed);
for(const name of actual.keys()) if(!deployedSet.has(name)){ console.error(`FAIL: live config declares undeployed ${name}`); failed=true; }
if(!/\benable_signup\s*=\s*true\b/.test(actualText)){ console.error('FAIL: enable_signup must be true'); failed=true; }
if(!/\[auth\.external\.google\][^[]*\benabled\s*=\s*true\b/.test(actualText)){ console.error('FAIL: Google Auth must be enabled'); failed=true; }
if(!/redirect_uri\s*=\s*"env\(GOOGLE_SIGNIN_CALLBACK_URL\)"/.test(actualText)){ console.error('FAIL: Google callback env drift'); failed=true; }
if(failed) process.exit(1);
console.log(`OK: frozen=${normative.size}; live/deployed=${deployed.length}; auth classifications aligned.`);
