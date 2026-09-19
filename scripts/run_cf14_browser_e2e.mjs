import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createServer, request as httpRequest } from 'node:http';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const APP_URL = 'http://127.0.0.1:4173/today';
const MOCK_SUPABASE_URL = 'http://127.0.0.1:4173';
const VITE_URL = 'http://127.0.0.1:4174';
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
const state = { mode: 'normal', failAfterMutation: false, initialBriefDelayMs: 850, requestLog: [], browserEvents: [], networkEvents: [] };

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

function corsHeaders(requestHeaders = {}) {
  const requestedHeaders = requestHeaders['access-control-request-headers'];
  return {
    'access-control-allow-origin': 'http://127.0.0.1:4173',
    'access-control-allow-headers': typeof requestedHeaders === 'string' && requestedHeaders.trim()
      ? requestedHeaders
      : 'authorization, apikey, content-type, x-client-info, x-supabase-api-version',
    'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS',
  };
}

function writeJsonResponse(response, value, statusCode = 200, requestHeaders = {}) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(statusCode, {
    ...corsHeaders(requestHeaders),
    'content-type': 'application/json; charset=utf-8',
    'content-range': '0-0/1',
  });
  response.end(JSON.stringify(value));
}

function writeNoContentResponse(response, requestHeaders = {}) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(204, corsHeaders(requestHeaders));
  response.end();
}

async function readRequestBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf8');
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
  if (exact && exact !== TODAY) return [];
  if (url.searchParams.getAll('status').some((value) => value === 'eq.completed')) {
    return task.status === 'completed' ? [task] : [];
  }
  return [task];
}

async function handleMockSupabaseRequest(request, response) {
  const url = new URL(request.url ?? '/', MOCK_SUPABASE_URL);
  state.requestLog.push({
    requestId: `http-${state.requestLog.length + 1}`,
    method: request.method,
    url: url.toString(),
    headers: request.headers,
    mode: state.mode,
    failAfterMutation: state.failAfterMutation,
  });

  if (request.method === 'OPTIONS') {
    writeNoContentResponse(response, request.headers);
    return;
  }

  const pathname = url.pathname;
  if (pathname === '/rest/v1/household_members') {
    writeJsonResponse(response, url.searchParams.has('user_id') && !url.searchParams.has('household_id') ? membership : [membership], 200, request.headers);
  } else if (pathname === '/rest/v1/households') {
    writeJsonResponse(response, household, 200, request.headers);
  } else if (pathname === '/rest/v1/profiles') {
    writeJsonResponse(response, [{ user_id: membership.user_id, display_name: 'パパ' }], 200, request.headers);
  } else if (pathname === '/rest/v1/rpc/get_my_daily_brief') {
    if (state.mode === 'initial-error') {
      writeJsonResponse(response, { code: 'CF14_INITIAL', message: 'CF14_BROWSER_INITIAL_READ_FAILED' }, 500, request.headers);
    } else if (state.failAfterMutation) {
      writeJsonResponse(response, { code: 'CF14_STALE', message: 'CF14_BROWSER_STALE_REFRESH' }, 500, request.headers);
    } else {
      if (state.initialBriefDelayMs > 0) await sleep(state.initialBriefDelayMs);
      writeJsonResponse(response, dailyBrief(), 200, request.headers);
    }
  } else if (pathname === '/rest/v1/task_instances') {
    writeJsonResponse(response, planningTaskRows(url), 200, request.headers);
  } else if (pathname === '/rest/v1/requests') {
    writeJsonResponse(response, [consultationRequest], 200, request.headers);
  } else if (pathname === '/rest/v1/request_attempts') {
    writeJsonResponse(response, [consultationAttempt], 200, request.headers);
  } else if (pathname.startsWith('/rest/v1/')) {
    writeJsonResponse(response, [], 200, request.headers);
  } else if (pathname === '/functions/v1/list-pending-actions') {
    writeJsonResponse(response, [], 200, request.headers);
  } else if (pathname === '/functions/v1/get-current-routine-sessions') {
    writeJsonResponse(response, { sessions: [] }, 200, request.headers);
  } else if (pathname === '/functions/v1/get-today-schedule') {
    writeJsonResponse(response, { household_id: household.id, local_date: TODAY, calendar_connected: false, calendar_stale: false, occurrences: [], assignments: [] }, 200, request.headers);
  } else if (pathname === '/functions/v1/complete-task') {
    // Drain the upload before responding. Returning while Chromium is still
    // streaming the JSON body can surface as net::ERR_ABORTED even though the
    // mock handler was entered, which would be false transport evidence.
    await readRequestBody(request);
    state.failAfterMutation = true;
    writeJsonResponse(response, { task_id: task.id, status: 'completed' }, 200, request.headers);
  } else if (pathname === '/functions/v1/negotiate-request') {
    const requestBody = await readRequestBody(request);
    const command = requestBody ? JSON.parse(requestBody) : {};
    consultationCommands.push(command);
    consultationAttempt.state = 'accepted';
    consultationAttempt.revision += 1;
    consultationRequest.status = 'accepted';
    writeJsonResponse(response, { state: 'accepted' }, 200, request.headers);
  } else if (pathname.startsWith('/functions/v1/')) {
    writeJsonResponse(response, {}, 200, request.headers);
  } else if (pathname === '/auth/v1/user') {
    writeJsonResponse(response, { id: membership.user_id, aud: 'authenticated', role: 'authenticated' }, 200, request.headers);
  } else {
    writeJsonResponse(response, { message: `Unhandled CF-14 mock path: ${pathname}` }, 404, request.headers);
  }
}

function isMockSupabasePath(url = '/') {
  return url.startsWith('/rest/v1/')
    || url.startsWith('/functions/v1/')
    || url.startsWith('/auth/v1/')
    || url.startsWith('/realtime/v1/');
}

function proxyToVite(request, response) {
  const upstream = httpRequest({
    hostname: '127.0.0.1',
    port: 4174,
    path: request.url ?? '/',
    method: request.method,
    headers: { ...request.headers, host: '127.0.0.1:4174' },
  }, (upstreamResponse) => {
    const headers = { ...upstreamResponse.headers };
    delete headers.connection;
    response.writeHead(upstreamResponse.statusCode ?? 502, headers);
    upstreamResponse.pipe(response);
  });
  upstream.on('error', (error) => {
    state.browserEvents.push({ kind: 'vite-proxy-error', url: request.url ?? null, error: String(error) });
    if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    if (!response.writableEnded) response.end('CF14 Vite proxy failure');
  });
  request.pipe(upstream);
}

async function startMockSupabase() {
  const server = createServer((request, response) => {
    if (!isMockSupabasePath(request.url ?? '/')) {
      proxyToVite(request, response);
      return;
    }
    void handleMockSupabaseRequest(request, response).catch((error) => {
      state.browserEvents.push({ kind: 'mock-server-error', url: request.url ?? null, error: String(error) });
      if (!response.headersSent && !response.destroyed) {
        writeJsonResponse(response, { message: 'CF14 mock server failure' }, 500, request.headers);
      } else if (!response.destroyed) {
        response.destroy(error instanceof Error ? error : new Error(String(error)));
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(4173, '127.0.0.1', resolve);
  });
  return server;
}

async function stopServer(server) {
  if (!server?.listening) return;
  await new Promise((resolve) => server.close(() => resolve()));
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
  await waitForPath(client, '/concierge');
  await waitForText(client, '思いついたことを、そのまま書いてください');
}

async function startVite() {
  const child = spawn(process.platform === 'win32' ? 'npm.cmd' : 'npm', [
    'run', 'dev', '-w', 'apps/web', '--', '--host', '127.0.0.1', '--port', '4174', '--strictPort',
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
    try { return (await fetch(VITE_URL)).ok; } catch { return false; }
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
  let mockSupabase;
  let vite;
  let chrome;
  let client;
  try {
    mockSupabase = await startMockSupabase();
    vite = await startVite();
    chrome = await startChrome();
    client = new CdpClient(chrome.page.webSocketDebuggerUrl);
    await client.connect();
    await client.send('Page.enable');
    await client.send('Runtime.enable');
    await client.send('Network.enable');
    await client.send('Log.enable');
    const networkRequestUrls = new Map();
    client.on('Network.requestWillBeSent', ({ requestId, request }) => {
      if (requestId && request?.url) networkRequestUrls.set(requestId, request.url);
    });
    client.on('Log.entryAdded', ({ entry }) => {
      if (entry?.level === 'error' || entry?.level === 'warning') {
        state.browserEvents.push({ kind: `browser-log-${entry.level}`, text: entry.text ?? '', url: entry.url ?? null });
      }
    });
    client.on('Network.responseReceived', ({ requestId, response }) => {
      if (response?.status >= 400 || response?.url?.includes('/functions/v1/complete-task')) {
        state.networkEvents.push({
          kind: 'http',
          requestId: requestId ?? null,
          status: response?.status ?? null,
          url: response?.url ?? null,
          headers: response?.headers ?? null,
        });
      }
    });
    client.on('Network.loadingFailed', ({ requestId, errorText, blockedReason, corsErrorStatus, type }) => {
      state.networkEvents.push({
        kind: 'loading-failed',
        requestId: requestId ?? null,
        url: requestId ? networkRequestUrls.get(requestId) ?? null : null,
        errorText,
        blockedReason: blockedReason ?? null,
        corsErrorStatus: corsErrorStatus ?? null,
        type: type ?? null,
      });
    });
    client.on('Runtime.exceptionThrown', ({ exceptionDetails }) => {
      state.browserEvents.push({ kind: 'exception', text: exceptionDetails?.exception?.description ?? exceptionDetails?.text ?? 'unknown exception' });
    });
    client.on('Runtime.consoleAPICalled', ({ type, args }) => {
      if (type === 'error' || type === 'warning') {
        state.browserEvents.push({ kind: `console-${type}`, text: (args ?? []).map((arg) => arg.value ?? arg.description ?? '').join(' ') });
      }
    });
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
    for (const removedKpi of ['要対応 0', '残り 1', '待ち 0', '明日影響 0']) {
      assert.equal(
        await evaluate(client, `document.body.innerText.includes(${JSON.stringify(removedKpi)})`),
        false,
        `removed Today dashboard text must stay absent: ${removedKpi}`,
      );
    }
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-READY',
      entryBoundary: 'real Chrome rendered Today route after HTTP reads',
      visibleAssertion: `${task.title} is rendered from the canonical Today contract without the removed KPI dashboard row`,
      screenshot: await screenshot(client, 'today-ready.png'),
    });

    await openConciergeFromQuickAdd(client);
    await waitForText(client, '思いついたことを、そのまま書いてください');
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

    // The Back/return scenario intentionally causes browser navigation and
    // cancels superseded reads. Start the stale-state mutation scenario from a
    // fresh Today navigation so those cancelled requests cannot invalidate the
    // mutation interception under test.
    state.initialBriefDelayMs = 0;
    state.failAfterMutation = false;
    await navigate(client, APP_URL);
    await waitForText(client, task.title);
    await sleep(150);

    assert.equal(await evaluate(client, `(() => {
      const buttons = [...document.querySelectorAll('button[aria-label=${JSON.stringify(`${task.title}を完了にする`)}]')];
      const button = buttons.at(-1); if (!button) return false; button.click(); return true;
    })()`), true, 'Nested Today task completion action must exist');
    await waitForText(client, '通信が不安定なため、最後に取得できた内容を表示しています。', 8_000);
    await waitForText(client, task.title, 2_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-STALE',
      entryBoundary: 'real task interaction succeeds, then canonical Today refresh fails',
      visibleAssertion: 'stale-state guidance is visible while the previously rendered task remains visible',
      screenshot: await screenshot(client, 'today-stale-refresh.png'),
    });

    state.mode = 'initial-error';
    state.failAfterMutation = false;
    await navigate(client, `${APP_URL}?cf14=initial-error`);
    await waitForText(client, 'サーバーへ接続できませんでした。', 8_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-ERROR',
      entryBoundary: 'real Chrome Today navigation with failing canonical read',
      visibleAssertion: 'the bounded-read connection error is rendered as the user-visible read failure',
      screenshot: await screenshot(client, 'today-error.png'),
    });

    // XC-02: exercise the sender's actual Requests route, not an isolated JSX
    // fixture. HTTP is controlled authoring evidence, not a real-provider claim.
    state.mode = 'normal';
    await navigate(client, 'http://127.0.0.1:4173/requests');
    await waitForText(client, consultationRequest.shared_title);
    await waitForText(client, '表示中の条件版を確認する');
    const setTerms = async (value) => evaluate(client, `(() => {
      const input = document.querySelector('input[aria-label="相談メモ"]');
      if (!input) return false;
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ${JSON.stringify(value)});
      input.dispatchEvent(new Event('input', { bubbles: true })); return true;
    })()`);
    assert.equal(await setTerms('園で引き継ぐ'), true);
    await waitFor(() => evaluate(client, `[...document.querySelectorAll('button')].find(b => b.textContent === '表示中の条件版を確認する')?.disabled === true`), { label: 'unsent terms cannot confirm saved version' });
    assert.equal(consultationCommands.length, 0);
    await setTerms('玄関で引き継ぐ');
    await waitFor(() => evaluate(client, `[...document.querySelectorAll('button')].find(b => b.textContent === '表示中の条件版を確認する')?.disabled === false`), { label: 'saved terms can be confirmed' });
    await evaluate(client, `[...document.querySelectorAll('button')].find(b => b.textContent === '表示中の条件版を確認する').scrollIntoView({ block: 'center', behavior: 'instant' })`);
    const point = await waitFor(() => evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find(b => b.textContent === '表示中の条件版を確認する');
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
  } catch (error) {
    const diagnostic = {
      error: error instanceof Error ? error.stack ?? error.message : String(error),
      url: client ? await evaluate(client, 'window.location.href').catch(() => null) : null,
      bodyText: client ? await evaluate(client, 'document.body?.innerText ?? ""').catch(() => null) : null,
      requestLog: state.requestLog,
      browserEvents: state.browserEvents,
      networkEvents: state.networkEvents,
      authenticatedAppModule: await fetch(`${VITE_URL}/src/app/AuthenticatedApp.tsx`).then(async (response) => ({ status: response.status, body: (await response.text()).slice(0, 16_000) })).catch((moduleError) => ({ error: String(moduleError) })),
    };
    await writeFile(path.join(ARTIFACT_DIR, 'failure-diagnostic.json'), `${JSON.stringify(diagnostic, null, 2)}\n`);
    console.error(`[cf14-browser] FAILURE DIAGNOSTIC ${JSON.stringify(diagnostic)}`);
    throw error;
  } finally {
    client?.close();
    await stopChild(chrome?.child);
    await stopChild(vite);
    await stopServer(mockSupabase);
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
