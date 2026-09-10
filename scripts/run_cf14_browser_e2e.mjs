import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const APP_URL = 'http://127.0.0.1:4173/today';
const MOCK_SUPABASE_URL = 'http://127.0.0.1:54321';
const ARTIFACT_DIR = path.resolve('artifacts/cf14-browser');
const SOURCE_HEAD = process.env.CF14_SOURCE_HEAD || process.env.GITHUB_HEAD_SHA || process.env.GITHUB_SHA || 'local-authoring';
const TODAY = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit',
}).format(new Date());
const JST_HOUR = new Date(Date.now() + 9 * 60 * 60 * 1000).getUTCHours();
const ACTIVE_TASK_GROUP = JST_HOUR < 11 ? 'morning' : JST_HOUR < 17 ? 'daytime' : 'evening';

const membership = {
  household_id: 'household-cf14', user_id: 'user-cf14', member_role: 'adult', family_role: 'papa',
  joined_at: '2026-01-01T00:00:00Z',
};
const household = {
  id: membership.household_id, name: 'CF14 Browser Household', timezone: 'Asia/Tokyo',
  evening_routine_setup_completed_at: '2026-01-01T00:00:00Z',
  dropoff_pickup_setup_completed_at: '2026-01-01T00:00:00Z',
  morning_preparation_setup_completed_at: '2026-01-01T00:00:00Z',
  connections_setup_completed_at: '2026-01-01T00:00:00Z',
  notification_preferences_setup_completed_at: '2026-01-01T00:00:00Z',
  onboarding_preview_completed_at: '2026-01-01T00:00:00Z',
};
const task = {
  id: 'task-cf14-browser', household_id: household.id, task_definition_id: null, recurrence_rule_id: null,
  origin: 'manual', title: 'ブラウザ証拠タスク', category: 'other', routine_phase: null, scheduled_date: TODAY,
  due_at: null, calendar_ends_at: null, calendar_visibility: 'hidden', task_kind: 'generic_once',
  planned_assignee_id: membership.user_id, assignment_mode: 'person', completion_mode: 'whole', status: 'todo',
  actual_completed_by_id: null, completed_at: null, attention_state: 'active', waiting_note: null,
  next_check_at: null, revision: 3, task_definitions: null,
};
const consultationRequest = {
  id: 'request-cf14-consultation', household_id: household.id,
  requester_id: membership.user_id, recipient_id: 'partner-cf14',
  shared_title: 'お迎えの相談', shared_message: '玄関で引き継ぐ', status: 'pending', due_at: null,
};
const consultationAttempt = {
  id: 'attempt-cf14-consultation', request_id: consultationRequest.id,
  state: 'awaiting_confirmation', revision: 4, terms_revision: 2,
  terms: { candidate: '玄関で引き継ぐ' }, reply_due_at: null,
};
const consultationCommands = [];
const state = { mode: 'normal', failAfterMutation: false, initialBriefDelayMs: 850, requestLog: [] };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(predicate, { timeoutMs = 10_000, intervalMs = 50, label = 'condition' } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await predicate();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await sleep(intervalMs);
  }
  if (lastError) throw new Error(`Timed out waiting for ${label}: ${lastError.message}`);
  throw new Error(`Timed out waiting for ${label}`);
}

function findChrome() {
  for (const candidate of [process.env.CHROME_BIN, 'google-chrome-stable', 'google-chrome', 'chromium', 'chromium-browser'].filter(Boolean)) {
    try { return execFileSync('which', [candidate], { encoding: 'utf8' }).trim(); } catch { /* try next */ }
  }
  throw new Error('CF-14 real-browser evidence requires a preinstalled Chrome/Chromium binary.');
}

class CdpClient {
  constructor(url) {
    this.url = url;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.url);
    await new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(String(event.data));
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`));
        else pending.resolve(message.result ?? {});
        return;
      }
      for (const handler of this.listeners.get(message.method) ?? []) {
        Promise.resolve(handler(message.params ?? {})).catch((error) => console.error(`[cf14-browser] ${message.method}`, error));
      }
    });
  }

  on(method, handler) {
    this.listeners.set(method, [...(this.listeners.get(method) ?? []), handler]);
  }

  send(method, params = {}) {
    assert.ok(this.socket?.readyState === WebSocket.OPEN, `CDP socket must be open before ${method}`);
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() { this.socket?.close(); }
}

function jsonResponse(value, responseCode = 200) {
  return {
    responseCode,
    responseHeaders: [
      { name: 'access-control-allow-origin', value: 'http://127.0.0.1:4173' },
      { name: 'access-control-allow-headers', value: '*' },
      { name: 'access-control-allow-methods', value: 'GET,POST,PATCH,DELETE,OPTIONS' },
      { name: 'content-type', value: 'application/json; charset=utf-8' },
      { name: 'content-range', value: '0-0/1' },
    ],
    body: Buffer.from(JSON.stringify(value)).toString('base64'),
  };
}

function noContentResponse() {
  return {
    responseCode: 204,
    responseHeaders: [
      { name: 'access-control-allow-origin', value: 'http://127.0.0.1:4173' },
      { name: 'access-control-allow-headers', value: '*' },
      { name: 'access-control-allow-methods', value: 'GET,POST,PATCH,DELETE,OPTIONS' },
    ],
  };
}

function dailyBrief() {
  const ownTaskGroups = { morning: [], daytime: [], evening: [], optional: [] };
  ownTaskGroups[ACTIVE_TASK_GROUP] = [{ task_id: task.id, title: task.title, due_at: task.due_at }];
  return {
    tasks: [{ task_id: task.id }], carryover: [], already_handled: [], urgent_actions: [],
    handovers: [], shopping: [], schedule: [], own_task_groups: ownTaskGroups,
  };
}

function planningTaskRows(url) {
  const filters = url.searchParams.getAll('scheduled_date');
  if (filters.some((value) => value.startsWith('gte.') || value.startsWith('lte.'))) return [];
  const exact = filters.find((value) => value.startsWith('eq.'))?.slice(3);
  return exact && exact !== TODAY ? [] : [task];
}

async function fulfillSupabaseRequest(client, { requestId, request }) {
  const url = new URL(request.url);
  state.requestLog.push({ method: request.method, url: request.url, mode: state.mode, failAfterMutation: state.failAfterMutation });
  if (request.method === 'OPTIONS') {
    await client.send('Fetch.fulfillRequest', { requestId, ...noContentResponse() });
    return;
  }

  const pathname = url.pathname;
  let response;
  if (pathname === '/rest/v1/household_members') {
    response = url.searchParams.has('user_id') && !url.searchParams.has('household_id') ? jsonResponse(membership) : jsonResponse([membership]);
  } else if (pathname === '/rest/v1/households') {
    response = jsonResponse(household);
  } else if (pathname === '/rest/v1/profiles') {
    response = jsonResponse([{ user_id: membership.user_id, display_name: 'パパ' }]);
  } else if (pathname === '/rest/v1/rpc/get_my_daily_brief') {
    if (state.mode === 'initial-error') response = jsonResponse({ code: 'CF14_INITIAL', message: 'CF14_BROWSER_INITIAL_READ_FAILED' }, 500);
    else if (state.failAfterMutation) response = jsonResponse({ code: 'CF14_STALE', message: 'CF14_BROWSER_STALE_REFRESH' }, 500);
    else {
      if (state.initialBriefDelayMs > 0) await sleep(state.initialBriefDelayMs);
      response = jsonResponse(dailyBrief());
    }
  } else if (pathname === '/rest/v1/task_instances') {
    response = jsonResponse(planningTaskRows(url));
  } else if (pathname === '/rest/v1/requests') {
    response = jsonResponse([consultationRequest]);
  } else if (pathname === '/rest/v1/request_attempts') {
    response = jsonResponse([consultationAttempt]);
  } else if (pathname.startsWith('/rest/v1/')) {
    response = jsonResponse([]);
  } else if (pathname === '/functions/v1/list-pending-actions') {
    response = jsonResponse([]);
  } else if (pathname === '/functions/v1/get-current-routine-sessions') {
    response = jsonResponse({ sessions: [] });
  } else if (pathname === '/functions/v1/get-today-schedule') {
    response = jsonResponse({ household_id: household.id, local_date: TODAY, calendar_connected: false, calendar_stale: false, occurrences: [], assignments: [] });
  } else if (pathname === '/functions/v1/complete-task') {
    state.failAfterMutation = true;
    response = jsonResponse({ task_id: task.id, status: 'completed' });
  } else if (pathname === '/functions/v1/negotiate-request') {
    const command = JSON.parse(request.postData ?? '{}');
    consultationCommands.push(command);
    consultationAttempt.state = 'accepted';
    consultationAttempt.revision += 1;
    consultationRequest.status = 'accepted';
    response = jsonResponse({ state: 'accepted' });
  } else if (pathname.startsWith('/functions/v1/')) {
    response = jsonResponse({});
  } else if (pathname === '/auth/v1/user') {
    response = jsonResponse({ id: membership.user_id, aud: 'authenticated', role: 'authenticated' });
  } else {
    response = jsonResponse({ message: `Unhandled CF-14 mock path: ${pathname}` }, 404);
  }
  await client.send('Fetch.fulfillRequest', { requestId, ...response });
}

async function evaluate(client, expression) {
  const result = await client.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || `Browser evaluation failed: ${expression}`);
  return result.result?.value;
}

const waitForText = (client, text, timeoutMs = 10_000) => waitFor(
  () => evaluate(client, `document.body?.innerText.includes(${JSON.stringify(text)}) === true`),
  { timeoutMs, label: `visible text ${JSON.stringify(text)}` },
);
const waitForPath = (client, pathname, timeoutMs = 10_000) => waitFor(
  () => evaluate(client, `window.location.pathname === ${JSON.stringify(pathname)}`),
  { timeoutMs, label: `pathname ${pathname}` },
);

async function screenshot(client, filename, captureBeyondViewport = true) {
  const { data } = await client.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport });
  const target = path.join(ARTIFACT_DIR, filename);
  await writeFile(target, Buffer.from(data, 'base64'));
  return path.relative(process.cwd(), target);
}

async function navigate(client, url) {
  await client.send('Page.navigate', { url });
  await waitFor(() => evaluate(client, `document.readyState === 'complete' || document.readyState === 'interactive'`), {
    timeoutMs: 10_000, label: `navigation to ${url}`,
  });
}

async function openConciergeFromQuickAdd(client) {
  const openedAdd = await evaluate(client, `(() => {
    const button = document.querySelector('button[aria-label="追加する"]');
    if (!button) return false; button.click(); return true;
  })()`);
  assert.equal(openedAdd, true, 'Today must expose the canonical Quick Add action');
  await waitForText(client, '追加するもの');
  const openedConcierge = await evaluate(client, `(() => {
    const button = [...document.querySelectorAll('button')].find((candidate) => candidate.textContent?.includes('おうちコンシェルジュ'));
    if (!button) return false; button.click(); return true;
  })()`);
  assert.equal(openedConcierge, true, 'Quick Add must expose the Concierge journey');
  await waitForPath(client, '/concierge');
}

async function startVite() {
  const child = spawn(process.platform === 'win32' ? 'npm.cmd' : 'npm', [
    'run', 'dev', '-w', 'apps/web', '--', '--host', '127.0.0.1', '--port', '4173', '--strictPort',
  ], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      VITE_SUPABASE_URL: MOCK_SUPABASE_URL,
      VITE_SUPABASE_PUBLISHABLE_KEY: 'cf14-browser-publishable-key',
      VITE_APP_NAME: 'CF14 Browser Authoring',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', (chunk) => { output += String(chunk); });
  child.stderr.on('data', (chunk) => { output += String(chunk); });
  child.on('exit', (code) => { if (code) console.error(`[cf14-browser] Vite exited ${code}\n${output}`); });
  await waitFor(async () => {
    try { return (await fetch('http://127.0.0.1:4173/')).ok; } catch { return false; }
  }, { timeoutMs: 20_000, intervalMs: 100, label: 'Vite dev server' });
  return child;
}

async function startChrome() {
  const chromePath = findChrome();
  const userDataDir = await mkdtemp(path.join(os.tmpdir(), 'cf14-browser-'));
  const child = spawn(chromePath, [
    '--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--no-first-run',
    '--disable-default-apps', '--disable-background-networking', '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`, 'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  // Drain child pipes while Chrome starts. Keep diagnostics when CI cannot
  // reach DevTools; a missing browser must never become passing evidence.
  let chromeOutput = '';
  const collect = (chunk) => { chromeOutput = (chromeOutput + String(chunk)).slice(-16_000); };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  const activePortFile = path.join(userDataDir, 'DevToolsActivePort');
  const port = await waitFor(async () => {
    if (!existsSync(activePortFile)) return null;
    const [line] = (await readFile(activePortFile, 'utf8')).trim().split(/\r?\n/);
    return Number(line) || null;
  }, { timeoutMs: 45_000, label: 'Chrome DevTools port' }).catch(async (error) => {
    await writeFile(path.join(ARTIFACT_DIR, 'chrome-startup.log'), chromeOutput || 'Chrome produced no output.');
    child.kill('SIGKILL');
    throw new Error(`${error.message} (exit=${child.exitCode})\n${chromeOutput}`);
  });
  const page = await waitFor(async () => {
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    return list.find((entry) => entry.type === 'page' && entry.webSocketDebuggerUrl) ?? null;
  }, { timeoutMs: 5_000, label: 'Chrome page target' });
  return { child, userDataDir, page, chromePath };
}

async function stopChild(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([new Promise((resolve) => child.once('exit', resolve)), sleep(2_000)]);
  if (child.exitCode === null) child.kill('SIGKILL');
}

async function main() {
  await rm(ARTIFACT_DIR, { recursive: true, force: true });
  await mkdir(ARTIFACT_DIR, { recursive: true });
  let vite;
  let chrome;
  let client;
  try {
    vite = await startVite();
    chrome = await startChrome();
    client = new CdpClient(chrome.page.webSocketDebuggerUrl);
    await client.connect();
    client.on('Fetch.requestPaused', (params) => fulfillSupabaseRequest(client, params));
    await client.send('Page.enable');
    await client.send('Runtime.enable');
    await client.send('Fetch.enable', { patterns: [{ urlPattern: `${MOCK_SUPABASE_URL}/*`, requestStage: 'Request' }] });
    await client.send('Emulation.setDeviceMetricsOverride', { width: 393, height: 852, deviceScaleFactor: 3, mobile: true });

    const session = {
      access_token: 'cf14-browser-access-token', token_type: 'bearer', expires_in: 86_400,
      expires_at: Math.floor(Date.now() / 1000) + 86_400, refresh_token: 'cf14-browser-refresh-token',
      user: {
        id: membership.user_id, aud: 'authenticated', role: 'authenticated', email: 'cf14-browser@example.test',
        app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z',
      },
    };
    await client.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `localStorage.setItem('sb-127-auth-token', ${JSON.stringify(JSON.stringify(session))});`,
    });

    const browserVersion = await client.send('Browser.getVersion');
    const scenarios = [];
    state.mode = 'normal';
    state.failAfterMutation = false;
    state.initialBriefDelayMs = 850;
    await navigate(client, APP_URL);

    await waitForText(client, '読み込み中…', 8_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-LOADING',
      entryBoundary: 'real Chrome navigation → authenticated Today HTTP reads',
      visibleAssertion: '読み込み中… is visible while canonical Today read is unresolved',
      screenshot: await screenshot(client, 'today-loading.png'),
    });

    await waitForText(client, task.title, 12_000);
    await waitForText(client, '要対応 0', 12_000);
    await waitForText(client, '残り 1', 12_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-READY',
      entryBoundary: 'real Chrome rendered Today route after HTTP reads',
      visibleAssertion: `${task.title}, 要対応 0, and 残り 1 are rendered from the canonical Today contract`,
      screenshot: await screenshot(client, 'today-ready.png'),
    });

    await openConciergeFromQuickAdd(client);
    await waitForText(client, 'おうちコンシェルジュ');
    assert.equal(await evaluate(client, `(() => {
      const textarea = document.querySelector('textarea'); if (!textarea) return false;
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(textarea, '戻り状態の下書き');
      textarea.dispatchEvent(new Event('input', { bubbles: true })); return true;
    })()`), true, 'Concierge textarea must exist');
    await sleep(50);
    assert.equal(await evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find((candidate) => candidate.textContent?.includes('戻る'));
      if (!button) return false; button.click(); return true;
    })()`), true, 'Concierge must expose a Back action');
    await waitForPath(client, '/today');
    await waitForText(client, task.title);
    await openConciergeFromQuickAdd(client);
    await waitFor(() => evaluate(client, `document.querySelector('textarea')?.value === '戻り状態の下書き'`), {
      timeoutMs: 5_000, label: 'Concierge draft restored after returning from Today',
    });
    scenarios.push({
      scenarioId: 'CF14-BACK-RETURN-REAL-BROWSER',
      entryBoundary: 'Today Quick Add → Concierge → Back → Today Quick Add → Concierge in real Chrome',
      visibleAssertion: 'Today context remains reachable and Concierge draft survives the canonical return journey',
      screenshot: await screenshot(client, 'back-return-draft.png'),
    });
    await evaluate(client, 'history.back()');
    await waitForPath(client, '/today');
    await waitForText(client, task.title);

    state.initialBriefDelayMs = 0;
    assert.equal(await evaluate(client, `(() => {
      const buttons = [...document.querySelectorAll('button[aria-label=${JSON.stringify(`${task.title}を完了にする`)}]')];
      const button = buttons.at(-1); if (!button) return false; button.click(); return true;
    })()`), true, 'Nested Today task completion action must exist');
    await waitForText(client, '読み込みに失敗しました。', 8_000);
    await waitForText(client, task.title, 2_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-STALE',
      entryBoundary: 'real task interaction succeeds, then canonical Today refresh fails',
      visibleAssertion: '読み込みに失敗しました。 is visible while the previously rendered task remains visible',
      screenshot: await screenshot(client, 'today-stale-refresh.png'),
    });

    state.mode = 'initial-error';
    state.failAfterMutation = false;
    await navigate(client, `${APP_URL}?cf14=initial-error`);
    await waitForText(client, '読み込みに失敗しました。', 8_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-ERROR',
      entryBoundary: 'real Chrome Today navigation with failing canonical read',
      visibleAssertion: '読み込みに失敗しました。 is rendered as the user-visible read failure',
      screenshot: await screenshot(client, 'today-error.png'),
    });

    // XC-02: exercise the sender's actual Requests route, not an isolated JSX
    // fixture. HTTP is controlled authoring evidence, not a real-provider claim.
    state.mode = 'normal';
    await navigate(client, 'http://127.0.0.1:4173/requests');
    await waitForText(client, consultationRequest.shared_title);
    await waitForText(client, 'この条件で確認する');
    const setTerms = async (value) => evaluate(client, `(() => {
      const input = document.querySelector('input[aria-label="合意する条件"]');
      if (!input) return false;
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ${JSON.stringify(value)});
      input.dispatchEvent(new Event('input', { bubbles: true })); return true;
    })()`);
    assert.equal(await setTerms('園で引き継ぐ'), true);
    await waitFor(() => evaluate(client, `[...document.querySelectorAll('button')].find(b => b.textContent === 'この条件で確認する')?.disabled === true`), { label: 'unsent terms cannot confirm saved version' });
    assert.equal(consultationCommands.length, 0);
    await setTerms('玄関で引き継ぐ');
    await waitFor(() => evaluate(client, `[...document.querySelectorAll('button')].find(b => b.textContent === 'この条件で確認する')?.disabled === false`), { label: 'saved terms can be confirmed' });
    await evaluate(client, `[...document.querySelectorAll('button')].find(b => b.textContent === 'この条件で確認する').scrollIntoView({ block: 'center', behavior: 'instant' })`);
    const point = await waitFor(() => evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find(b => b.textContent === 'この条件で確認する');
      const rect = button.getBoundingClientRect();
      const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
      return button.contains(document.elementFromPoint(x, y)) ? { x, y } : null;
    })()`), { label: 'sender confirmation is reachable without fixed-navigation obstruction' });
    const consultationScreenshot = await screenshot(client, 'request-sender-consultation.png', false);
    await client.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...point, button: 'left', clickCount: 1 });
    await client.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...point, button: 'left', clickCount: 1 });
    await waitFor(() => consultationCommands.length === 1, { label: 'sender canonical confirmation HTTP' });
    const command = consultationCommands[0];
    assert.equal(command.request_id, consultationRequest.id);
    assert.equal(command.attempt_id, consultationAttempt.id);
    assert.equal(command.action, 'confirm_terms');
    assert.equal(command.expected_revision, 4);
    assert.equal(command.expected_terms_revision, 2);
    await waitForText(client, '履歴 1');
    scenarios.push({
      scenarioId: 'CF14-REQUEST-SENDER-CONSULTATION-REAL-BROWSER',
      entryBoundary: 'authenticated Requests route → sender consultation → canonical confirmation HTTP → refreshed history',
      visibleAssertion: 'Unsent edited terms cannot be confirmed; saved revision 2 can be confirmed by the sender and canonical reload updates the request bucket.',
      screenshot: consultationScreenshot,
    });

    const evidence = {
      status: 'F1_AUTHORING_EVIDENCE_ONLY', cf14Status: 'FAIL/PENDING', sourceHead: SOURCE_HEAD,
      capturedAt: new Date().toISOString(), appUrl: APP_URL,
      browser: {
        product: browserVersion.product, userAgent: browserVersion.userAgent, jsVersion: browserVersion.jsVersion,
        executable: chrome.chromePath, viewport: '393x852', physicalDevice: false,
      },
      scenarios, requestCount: state.requestLog.length, requestLog: state.requestLog,
      note: 'Real-Chrome F1 authoring evidence. This is not physical-iPhone evidence and cannot by itself satisfy final F2.',
    };
    await writeFile(path.join(ARTIFACT_DIR, 'evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    console.log(`[cf14-browser] PASS ${scenarios.length} real-browser authoring scenarios; CF-14 remains FAIL/PENDING.`);
  } finally {
    client?.close();
    await stopChild(chrome?.child);
    await stopChild(vite);
    if (chrome?.userDataDir) {
      try {
        await rm(chrome.userDataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      } catch (error) {
        console.warn(`[cf14-browser] Chrome profile cleanup did not complete: ${error.message}`);
      }
    }
  }
}

await main();
