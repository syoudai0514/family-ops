import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { access, readFile } from 'node:fs/promises';
import path from 'node:path';

const PASS_MARKER = '[cf14-browser] PASS 5 real-browser authoring scenarios;';
const TIMEOUT_MS = 60_000;
const detached = process.platform !== 'win32';
const artifactDir = path.resolve('artifacts/cf14-browser');
const expectedScenarioIds = [
  'CF14-TODAY-REAL-BROWSER-LOADING',
  'CF14-TODAY-REAL-BROWSER-READY',
  'CF14-BACK-RETURN-REAL-BROWSER',
  'CF14-TODAY-REAL-BROWSER-STALE',
  'CF14-TODAY-REAL-BROWSER-ERROR',
];

function stopProcessTree(child) {
  if (!child || child.exitCode !== null) return;
  try {
    if (detached) process.kill(-child.pid, 'SIGTERM');
    else child.kill('SIGTERM');
  } catch {
    // The process may have already exited between the exitCode check and kill.
  }
}

async function validateEvidenceArtifact() {
  const evidencePath = path.join(artifactDir, 'evidence.json');
  const evidence = JSON.parse(await readFile(evidencePath, 'utf8'));
  assert.equal(evidence.status, 'F1_AUTHORING_EVIDENCE_ONLY');
  assert.equal(evidence.cf14Status, 'FAIL/PENDING');
  assert.equal(evidence.sourceHead, process.env.CF14_SOURCE_HEAD || process.env.GITHUB_HEAD_SHA || process.env.GITHUB_SHA || 'local-authoring');
  assert.equal(evidence.browser?.physicalDevice, false, 'real-Chrome evidence must not masquerade as physical-iPhone evidence');
  assert.match(evidence.browser?.product ?? '', /Chrome|Chromium/i, 'browser product must identify real Chrome/Chromium');
  assert.deepEqual(evidence.scenarios?.map((scenario) => scenario.scenarioId), expectedScenarioIds);
  assert.ok(Number.isInteger(evidence.requestCount) && evidence.requestCount > 0, 'browser evidence must include HTTP-boundary requests');
  assert.equal(evidence.requestLog?.length, evidence.requestCount, 'request log count must be internally consistent');

  for (const scenario of evidence.scenarios) {
    assert.equal(typeof scenario.entryBoundary, 'string');
    assert.ok(scenario.entryBoundary.length > 0, `${scenario.scenarioId} needs an entry boundary`);
    assert.equal(typeof scenario.visibleAssertion, 'string');
    assert.ok(scenario.visibleAssertion.length > 0, `${scenario.scenarioId} needs a visible assertion`);
    assert.equal(typeof scenario.screenshot, 'string');
    await access(path.resolve(scenario.screenshot));
  }

  assert.ok(
    evidence.requestLog.some((entry) => entry.url?.includes('/functions/v1/complete-task')),
    'stale-refresh journey must include the real browser complete-task HTTP boundary',
  );
  assert.ok(
    evidence.requestLog.some((entry) => entry.url?.includes('/rest/v1/rpc/get_my_daily_brief') && entry.failAfterMutation === true),
    'stale-refresh journey must record a failed canonical read after mutation',
  );
}

const child = spawn(process.execPath, ['scripts/run_cf14_browser_e2e.mjs'], {
  cwd: process.cwd(),
  env: process.env,
  detached,
  stdio: ['ignore', 'pipe', 'pipe'],
});

let output = '';
let sawPass = false;
let settled = false;

const result = new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    if (settled) return;
    settled = true;
    stopProcessTree(child);
    reject(new Error(`CF-14 real-browser authoring E2E exceeded ${TIMEOUT_MS}ms without a valid PASS artifact.`));
  }, TIMEOUT_MS);

  async function confirmPass() {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    try {
      await validateEvidenceArtifact();
      console.log('[cf14-browser-supervisor] validated evidence.json, five screenshots, exact source HEAD, real Chrome identity, and HTTP-boundary trace.');
      stopProcessTree(child);
      resolve();
    } catch (error) {
      stopProcessTree(child);
      reject(error);
    }
  }

  function consume(chunk, stream) {
    const text = String(chunk);
    output += text;
    stream.write(text);
    if (!sawPass && output.includes(PASS_MARKER)) {
      sawPass = true;
      void confirmPass();
    }
  }

  child.stdout.on('data', (chunk) => consume(chunk, process.stdout));
  child.stderr.on('data', (chunk) => consume(chunk, process.stderr));
  child.once('error', (error) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    reject(error);
  });
  child.once('exit', (code, signal) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    reject(new Error(`CF-14 real-browser authoring E2E exited before validated PASS (code=${code}, signal=${signal}).\n${output}`));
  });
});

try {
  await result;
} finally {
  stopProcessTree(child);
}
