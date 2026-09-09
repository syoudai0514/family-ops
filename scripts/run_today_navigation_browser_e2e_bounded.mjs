import { spawn } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import path from 'node:path';

const ARTIFACT_DIR = path.resolve('artifacts/today-navigation-browser');
const EVIDENCE_FILE = path.join(ARTIFACT_DIR, 'evidence.json');
const RUNNER = path.resolve('scripts/run_today_navigation_browser_e2e.mjs');
const DEADLINE_MS = 45_000;
const GRACE_MS = 1_500;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function signalTree(child, signal) {
  if (!child?.pid) return;
  try {
    if (process.platform === 'win32') child.kill(signal);
    else process.kill(-child.pid, signal);
  } catch (error) {
    if (error?.code !== 'ESRCH') throw error;
  }
}

async function hasPassEvidence() {
  try {
    const evidence = JSON.parse(await readFile(EVIDENCE_FILE, 'utf8'));
    return evidence?.status === 'PASS';
  } catch {
    return false;
  }
}

await rm(ARTIFACT_DIR, { recursive: true, force: true });

const child = spawn(process.execPath, [RUNNER], {
  cwd: process.cwd(),
  env: process.env,
  stdio: 'inherit',
  detached: process.platform !== 'win32',
});

let exitResult = null;
const exited = new Promise((resolve) => {
  child.once('exit', (code, signal) => {
    exitResult = { code, signal };
    resolve(exitResult);
  });
});

const deadline = Date.now() + DEADLINE_MS;
while (Date.now() < deadline) {
  if (exitResult) {
    if (exitResult.code === 0 && await hasPassEvidence()) process.exit(0);
    throw new Error(`Browser scenario runner exited before PASS evidence (code=${exitResult.code}, signal=${exitResult.signal ?? 'none'}).`);
  }

  if (await hasPassEvidence()) {
    await Promise.race([exited, sleep(GRACE_MS)]);
    if (!exitResult) {
      signalTree(child, 'SIGTERM');
      await Promise.race([exited, sleep(GRACE_MS)]);
    }
    if (!exitResult) signalTree(child, 'SIGKILL');
    console.log('[today-browser-supervisor] PASS evidence captured; browser/dev-server process tree closed.');
    process.exit(0);
  }

  await Promise.race([exited, sleep(200)]);
}

signalTree(child, 'SIGTERM');
await Promise.race([exited, sleep(GRACE_MS)]);
if (!exitResult) signalTree(child, 'SIGKILL');
throw new Error(`Timed out after ${DEADLINE_MS}ms before PASS browser evidence was produced.`);
