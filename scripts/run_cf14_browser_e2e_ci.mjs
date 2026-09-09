import { spawn } from 'node:child_process';

const PASS_MARKER = '[cf14-browser] PASS ';
const TIMEOUT_MS = 60_000;
const detached = process.platform !== 'win32';

function stopProcessTree(child) {
  if (!child || child.exitCode !== null) return;
  try {
    if (detached) process.kill(-child.pid, 'SIGTERM');
    else child.kill('SIGTERM');
  } catch {
    // The process may have already exited between the exitCode check and kill.
  }
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
    reject(new Error(`CF-14 real-browser authoring E2E exceeded ${TIMEOUT_MS}ms without a PASS marker.`));
  }, TIMEOUT_MS);

  function consume(chunk, stream) {
    const text = String(chunk);
    output += text;
    stream.write(text);
    if (!sawPass && output.includes(PASS_MARKER)) {
      sawPass = true;
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        // The PASS marker is printed only after evidence.json and every
        // screenshot have been written. Terminate the detached process group
        // so npm/Vite/Chrome cannot keep the CI step alive after proof exists.
        stopProcessTree(child);
        resolve();
      }
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
    if (sawPass && code === 0) resolve();
    else reject(new Error(`CF-14 real-browser authoring E2E exited before PASS (code=${code}, signal=${signal}).\n${output}`));
  });
});

try {
  await result;
} finally {
  stopProcessTree(child);
}
