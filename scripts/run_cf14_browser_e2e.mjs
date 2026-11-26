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
const partner = { ...membership, user_id: 'partner-cf14', family_role: 'mama' };
const actorRefs = {
  [membership.user_id]: 'actor-cf14-papa',
  [partner.user_id]: 'actor-cf14-mama',
};
const parties = {
  household_id: household.id,
  requester_id: membership.user_id, requester_actor_ref_id: actorRefs[membership.user_id],
  recipient_id: partner.user_id, recipient_actor_ref_id: actorRefs[partner.user_id],
};
const consultationId = '01f00000-0000-4000-8000-000000000001';
const consultationTitle = 'お迎えの相談';
const consultationMessage = '今日のお迎えをお願いできる？';
const notificationTitle = '相談の内容を確認してください';
const consultationMemo = '園で引き継ぐ\n18時30分なら対応できます。';
const otherRequest = { ...parties, id: 'request-cf14-other', shared_title: '明日の買い物', status: 'pending', due_at: null };
const requests = [otherRequest];
const attempts = [{
  id: 'attempt-cf14-other', request_id: otherRequest.id,
  state: 'pending', revision: 1, terms_revision: 1, terms: {}, reply_due_at: null,
  request_attempt_confirmations: [],
}];
const requestCommands = [];
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

function writeEdgeJsonResponse(response, value, statusCode = 200) {
  if (response.destroyed || response.writableEnded) return;
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(body.length),
    'cache-control': 'no-store',
    connection: 'close',
  });
  response.end(body);
}

async function readRequestBody(request, label = 'request-body') {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let settled = false;
    const finish = (kind, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      state.browserEvents.push({
        kind: `mock-${kind}`,
        label,
        bytes: chunks.reduce((total, chunk) => total + chunk.length, 0),
        complete: request.complete,
        destroyed: request.destroyed,
      });
      value instanceof Error ? reject(value) : resolve(Buffer.concat(chunks).toString('utf8'));
    };
    const timer = setTimeout(() => finish('body-timeout', new Error(`${label} did not finish within 2000ms`)), 2_000);
    request.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
    request.once('end', () => finish('body-end'));
    request.once('aborted', () => finish('body-aborted', new Error(`${label} was aborted by the client`)));
    request.once('error', (error) => finish('body-error', error));
  });
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

  const requestBody = request.method === 'POST' || request.method === 'PATCH' || request.method === 'PUT'
    ? await readRequestBody(request, `${request.method} ${url.pathname}`)
    : '';
  const pathname = url.pathname;
  const actor = request.headers.authorization === 'Bearer cf14-browser-partner-token' ? partner : membership;
  const members = state.mode === 'consultation' ? [membership, partner] : [membership];
  if (pathname === '/rest/v1/household_members') {
    writeJsonResponse(response, url.searchParams.has('user_id') && !url.searchParams.has('household_id') ? actor : members, 200, request.headers);
  } else if (pathname === '/rest/v1/households') {
    writeJsonResponse(response, household, 200, request.headers);
  } else if (pathname === '/rest/v1/profiles') {
    writeJsonResponse(response, members.map((member) => ({ user_id: member.user_id, display_name: member.family_role === 'papa' ? 'パパ' : 'ママ' })), 200, request.headers);
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
    writeJsonResponse(response, state.mode === 'consultation' ? requests : [], 200, request.headers);
  } else if (pathname === '/rest/v1/request_attempts') {
    const includeConfirmations = url.searchParams.get('select')?.includes('request_attempt_confirmations(');
    const attemptRows = attempts.map(({ request_attempt_confirmations: confirmations, ...attempt }) =>
      includeConfirmations ? { ...attempt, request_attempt_confirmations: confirmations } : attempt);
    writeJsonResponse(response, state.mode === 'consultation' ? attemptRows : [], 200, request.headers);
  } else if (pathname === '/rest/v1/user_notifications') {
    const notified = attempts.some((attempt) => attempt.request_id === consultationId && attempt.state === 'awaiting_confirmation');
    writeJsonResponse(response, actor === membership && notified ? [{
      id: 'notification-cf14-consultation', household_id: household.id, recipient_user_id: membership.user_id,
      type: 'request.awaiting_confirmation', title: notificationTitle,
      body: notificationTitle + '\n' + consultationMemo, created_at: new Date().toISOString(),
      payload: { request_id: consultationId }, read_at: null,
    }] : [], 200, request.headers);
  } else if (pathname.startsWith('/rest/v1/')) {
    writeJsonResponse(response, [], 200, request.headers);
  } else if (pathname === '/functions/v1/list-pending-actions') {
    writeJsonResponse(response, [], 200, request.headers);
  } else if (pathname === '/functions/v1/complete-onboarding-step' && JSON.parse(requestBody).action === 'read') {
    writeEdgeJsonResponse(response, { members: [], children: [], contexts: [] });
  } else if (pathname === '/functions/v1/get-current-routine-sessions') {
    writeJsonResponse(response, { sessions: [] }, 200, request.headers);
  } else if (pathname === '/functions/v1/get-today-schedule') {
    writeJsonResponse(response, { household_id: household.id, local_date: TODAY, calendar_connected: false, calendar_stale: false, occurrences: [], assignments: [] }, 200, request.headers);
  } else if (pathname === '/functions/v1/complete-task') {
    // Drain the upload before responding. Returning while Chromium is still
    // streaming the JSON body can surface as net::ERR_ABORTED even though the
    // mock handler was entered, which would be false transport evidence.
    state.browserEvents.push({ kind: 'mock-complete-task-body', body: requestBody });
    response.once('finish', () => state.browserEvents.push({ kind: 'mock-complete-task-response-finish', statusCode: response.statusCode }));
    response.once('close', () => state.browserEvents.push({ kind: 'mock-complete-task-response-close', statusCode: response.statusCode }));
    state.failAfterMutation = true;
    writeEdgeJsonResponse(response, { task_id: task.id, status: 'completed' }, 200);
  } else if (pathname === '/functions/v1/send-request') {
    const command = JSON.parse(requestBody);
    assert.equal(actor.user_id, membership.user_id);
    assert.equal(command.recipient_user_id, partner.user_id);
    assert.equal(command.shared_title, consultationTitle);
    assert.equal(command.shared_message, consultationMessage);
    requestCommands.push({ actor: actor.user_id, endpoint: 'send-request', command });
    requests.push({ ...parties, id: consultationId, shared_title: command.shared_title, shared_message: command.shared_message, status: 'pending', due_at: null });
    attempts.push({
      id: 'attempt-cf14-consultation', request_id: consultationId,
      state: 'pending', revision: 1, terms_revision: 1, terms: {}, reply_due_at: null,
      request_attempt_confirmations: [],
    });
    writeEdgeJsonResponse(response, { request_id: consultationId });
  } else if (pathname === '/functions/v1/negotiate-request' || pathname === '/functions/v1/decline-request' || pathname === '/functions/v1/respond-request') {
    const command = JSON.parse(requestBody);
    const action = command.action ?? command.response_action ?? 'decline';
    const row = requests.find((entry) => entry.id === command.request_id);
    const attempt = attempts.find((entry) => entry.request_id === command.request_id);
    assert.ok(row && attempt);
    assert.equal(command.attempt_id, attempt.id);
    assert.equal(command.expected_revision, attempt.revision);
    assert.equal(command.expected_terms_revision, attempt.terms_revision);
    requestCommands.push({ actor: actor.user_id, endpoint: pathname.split('/').at(-1), command });
    switch (action) {
      case 'consult':
        assert.equal(actor.user_id, partner.user_id);
        attempt.state = 'consulting';
        break;
      case 'edit_terms':
        attempt.terms = command.terms;
        attempt.terms_revision += 1;
        attempt.state = 'consulting';
        break;
      case 'confirm_terms': {
        const actorRef = actorRefs[actor.user_id];
        const confirmations = attempt.request_attempt_confirmations;
        assert.ok(!confirmations.some((entry) => entry.actor_ref_id === actorRef && entry.terms_revision === attempt.terms_revision));
        confirmations.push({ actor_ref_id: actorRef, terms_revision: attempt.terms_revision });
        const confirmationCount = confirmations.filter((entry) => entry.terms_revision === attempt.terms_revision).length;
        attempt.state = confirmationCount >= 2 ? 'accepted' : 'awaiting_confirmation';
        if (attempt.state === 'accepted') row.status = 'accepted';
        break;
      }
      case 'decline':
      case 'decline_consultation':
        assert.equal(actor.user_id, partner.user_id);
        if (action === 'decline_consultation') assert.equal(attempt.state, 'consulting');
        attempt.state = 'declined';
        row.status = 'declined';
        break;
      default:
        assert.fail(`Unexpected request action: ${action}`);
    }
    attempt.revision += 1;
    writeEdgeJsonResponse(response, { state: attempt.state });
  } else if (pathname === '/functions/v1/propose-ai-draft' || pathname === '/functions/v1/confirm-request-draft') {
    assert.fail(`The manual request journey unexpectedly called ${pathname}`);
  } else if (pathname.startsWith('/functions/v1/')) {
    writeJsonResponse(response, {}, 200, request.headers);
  } else if (pathname === '/auth/v1/user') {
    writeJsonResponse(response, { id: actor.user_id, aud: 'authenticated', role: 'authenticated' }, 200, request.headers);
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

async function seedMobileSession(client, member) {
  await client.send('Emulation.setDeviceMetricsOverride', { width: 393, height: 852, deviceScaleFactor: 3, mobile: true });
  const session = {
    access_token: member.user_id === partner.user_id ? 'cf14-browser-partner-token' : 'cf14-browser-access-token',
    token_type: 'bearer', expires_in: 86_400,
    expires_at: Math.floor(Date.now() / 1000) + 86_400, refresh_token: 'cf14-browser-refresh-token',
    user: {
      id: member.user_id, aud: 'authenticated', role: 'authenticated', email: `${member.user_id}@example.test`,
      app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z',
    },
  };
  await client.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `localStorage.setItem('sb-127-auth-token', ${JSON.stringify(JSON.stringify(session))});`,
  });
}

function requestRow(title) {
  return `[...document.querySelectorAll('.request-item')].find(row => row.querySelector('strong')?.textContent === ${JSON.stringify(title)})`;
}

function buttonWithText(text, scope = 'document') {
  return `[...((${scope})?.querySelectorAll('button') ?? [])].find(button => button.textContent.trim() === ${JSON.stringify(text)})`;
}

async function tapButton(client, text, scope) {
  await tapElement(client, buttonWithText(text, scope), text);
}

async function tapElement(client, expression, label) {
  const point = await waitFor(() => evaluate(client, `(() => {
    const element = ${expression};
    if (!element || element.disabled) return null;
    element.scrollIntoView({ block: 'center', behavior: 'instant' });
    const rect = element.getBoundingClientRect();
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    return element.contains(document.elementFromPoint(x, y)) ? { x, y } : null;
  })()`), { label: `reachable element ${label}` });
  await client.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point] });
  await client.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
}

async function inputByLabel(client, scope, label, value) {
  const field = `[...document.querySelectorAll(${JSON.stringify(`${scope} label`)})]
    .find(label => label.textContent.trim() === ${JSON.stringify(label)})?.control`;
  await tapElement(client, field, label);
  await client.send('Input.insertText', { text: value });
}

async function assertNoHorizontalOverflow(client, selector) {
  const widths = await evaluate(client, `(() => {
    const node = document.querySelector(${JSON.stringify(selector)});
    return {
      viewport: document.documentElement.clientWidth, document: document.documentElement.scrollWidth,
      client: node?.clientWidth ?? 0, scroll: node?.scrollWidth ?? 0,
    };
  })()`);
  assert.equal(widths.viewport, 393);
  assert.ok(widths.document <= widths.viewport, `Page overflow at mobile width: ${JSON.stringify(widths)}`);
  assert.ok(widths.client > 0 && widths.scroll <= widths.client + 1, `Panel overflow at mobile width: ${selector} ${JSON.stringify(widths)}`);
}

async function openFocusedRequest(client, url, title) {
  await navigate(client, url);
  await waitForFocusedRequest(client, title);
}

function waitForFocusedRequest(client, title) {
  return waitFor(() => evaluate(client, `document.activeElement === (${requestRow(title)})`), { label: `focused request ${title}` });
}

async function runRequestJourney(sender, recipient) {
  const listUrl = `${MOCK_SUPABASE_URL}/requests`;
  const targetUrl = `${listUrl}?request=${consultationId}`;
  const targetRow = requestRow(consultationTitle);
  const confirmText = 'この案に同意する';
  const waitingForPartner = 'あなたは同意済みです。相手の返事を待っています。';
  const waitingForMe = '相手は同意済みです。内容を見て返事をしてください。';

  await navigate(sender, listUrl);
  await tapButton(sender, '+ お願いを送る');
  await inputByLabel(sender, '.request-composer', 'タイトル', consultationTitle);
  await inputByLabel(sender, '.request-composer', '相手へ送る文面', consultationMessage);
  await tapButton(sender, '送信内容を確認');
  await waitForText(sender, 'この内容で送りますか？');
  await waitForText(sender, consultationMessage);
  await waitForText(sender, '宛先　ママ');
  await assertNoHorizontalOverflow(sender, '.request-composer');
  assert.equal(requestCommands.length, 0, 'Opening the preview must not send the request');
  await tapButton(sender, 'この内容でお願いを送る');
  await waitForText(sender, 'ママへのお願いを送りました。');
  await waitForText(sender, consultationTitle);

  await openFocusedRequest(recipient, targetUrl, consultationTitle);
  await waitForText(recipient, otherRequest.shared_title);
  await waitForText(recipient, consultationMessage);
  await tapButton(recipient, 'その他の返答', targetRow);
  await tapButton(recipient, '相談する', targetRow);
  await waitForText(recipient, 'いまの相談案');
  await inputByLabel(recipient, '.request-consultation', '相手へ送る相談文', consultationMemo);
  await waitFor(() => evaluate(recipient, `(${buttonWithText(confirmText, targetRow)})?.disabled === true`), {
    label: 'unsent consultation edits disable confirmation of the saved version',
  });
  await tapButton(recipient, '相談案を送る', targetRow);
  await waitForText(recipient, consultationMemo);
  await tapButton(recipient, confirmText, targetRow);
  await waitForText(recipient, waitingForPartner);
  assert.equal(await evaluate(recipient, `Boolean(${buttonWithText(confirmText, targetRow)})`), false, 'The person who already agreed has no repeat confirmation action');
  await assertNoHorizontalOverflow(recipient, '.request-consultation');

  await navigate(sender, `${MOCK_SUPABASE_URL}/notifications`);
  await waitForText(sender, notificationTitle);
  await tapElement(sender, 'document.querySelector(".notification-copy summary")', notificationTitle);
  const notificationLink = `document.querySelector('.notification-copy a[href="/requests?request=${consultationId}"]')`;
  await tapElement(sender, notificationLink, 'お願いを開く');
  await waitForFocusedRequest(sender, consultationTitle);
  await waitForText(sender, consultationMemo);
  await waitForText(sender, waitingForMe);
  await assertNoHorizontalOverflow(sender, '.request-consultation');
  await evaluate(sender, `(${targetRow}).querySelector('.request-consultation').scrollIntoView({ block: 'center' })`);
  const consultationScreenshot = await screenshot(sender, 'request-sender-consultation.png', false);
  await tapButton(sender, confirmText, targetRow);
  await waitForText(sender, '履歴 1');

  // The same notification URL should open the row even when it has moved into history.
  await openFocusedRequest(recipient, targetUrl, consultationTitle);
  await waitForText(recipient, '引き受け済み');
  assert.equal(await evaluate(recipient, `(${buttonWithText('履歴 1')})?.classList.contains('active')`), true);
  await tapButton(recipient, '対応中 1');
  const otherRow = requestRow(otherRequest.shared_title);
  await tapButton(recipient, 'その他の返答', otherRow);
  await tapButton(recipient, '相談する', otherRow);
  await tapButton(recipient, '今回は難しい', otherRow);
  await waitForText(recipient, '「今回は難しい」と相手に伝えますか？');
  assert.equal(requestCommands.at(-1).command.action, 'consult');
  await tapButton(recipient, '難しいと伝える', otherRow);
  await waitForText(recipient, '履歴 2');

  assert.deepEqual(requestCommands.map(({ actor, endpoint, command }) => [actor, command.action ?? command.response_action ?? endpoint]), [
    [membership.user_id, 'send-request'],
    [partner.user_id, 'consult'],
    [partner.user_id, 'edit_terms'],
    [partner.user_id, 'confirm_terms'],
    [membership.user_id, 'confirm_terms'],
    [partner.user_id, 'consult'],
    [partner.user_id, 'decline_consultation'],
  ]);
  assert.equal(requestCommands[2].command.terms.candidate, consultationMemo);
  assert.equal(requestCommands[3].command.expected_terms_revision, 2);
  assert.equal(requestCommands[4].command.expected_terms_revision, 2);
  assert.equal(requestCommands[6].command.request_id, otherRequest.id);
  assert.equal(requestCommands[6].command.expected_revision, 2);

  assert.ok(state.requestLog.filter(({ url }) => url.includes('/functions/v1/')).every(({ url }) =>
    !url.endsWith('/propose-ai-draft') && !url.endsWith('/confirm-request-draft'),
  ), 'Manual request and consultation should make no AI draft calls');

  return {
    scenarioId: 'CF14-REQUEST-SENDER-CONSULTATION-REAL-BROWSER',
    entryBoundary: 'two authenticated mobile browser sessions → manual request preview/send → consultation → both confirmations → linked history and decline',
    visibleAssertion: 'The direct request preview precedes send, both users see the saved multiline proposal and their respective confirmation turn, and the same link opens the exact active or historical request.',
    screenshot: consultationScreenshot,
  };
}

async function main() {
  await rm(ARTIFACT_DIR, { recursive: true, force: true });
  await mkdir(ARTIFACT_DIR, { recursive: true });
  let mockSupabase;
  let vite;
  let chrome;
  let client;
  let partnerBrowser;
  let partnerClient;
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
    await seedMobileSession(client, membership);

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

    const rawFunctionFetchProbe = await evaluate(client, `(async () => {
      const controller = new AbortController();
      try {
        const response = await fetch('/functions/v1/list-pending-actions', {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            authorization: 'Bearer cf14-browser-access-token',
            apikey: 'cf14-browser-publishable-key',
          },
          body: '{}',
          signal: controller.signal,
        });
        return { ok: response.ok, status: response.status, text: await response.text() };
      } catch (error) {
        return { error: error?.name + ': ' + error?.message };
      }
    })()`);
    const exactManualFunctionProbe = await evaluate(client, `(async () => {
      try {
        const envModule = await import('/src/lib/env.ts');
        const supabaseModule = await import('/src/lib/supabaseClient.ts');
        const env = envModule.getAppEnv();
        const session = await supabaseModule.supabase.auth.getSession();
        const accessToken = session.data.session?.access_token;
        const controller = new AbortController();
        const response = await fetch(env.supabaseUrl + '/functions/v1/list-pending-actions', {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            authorization: 'Bearer ' + accessToken,
            apikey: env.supabasePublishableKey,
          },
          body: JSON.stringify({}),
          signal: controller.signal,
        });
        return { ok: response.ok, status: response.status, text: await response.text(), url: env.supabaseUrl };
      } catch (error) {
        return { error: error?.name + ': ' + error?.message };
      }
    })()`);
    const withinFunctionProbe = await evaluate(client, `(async () => {
      function withinProbe(promise, ms, onTimeout) {
        let timer;
        return new Promise((resolve, reject) => {
          let settled = false;
          timer = setTimeout(() => {
            if (settled) return;
            settled = true;
            onTimeout?.();
            reject(new Error('probe timeout'));
          }, ms);
          Promise.resolve(promise).then(
            (value) => {
              if (settled) return;
              settled = true;
              if (timer) clearTimeout(timer);
              resolve(value);
            },
            (error) => {
              if (settled) return;
              settled = true;
              if (timer) clearTimeout(timer);
              reject(error);
            },
          );
        });
      }
      try {
        const envModule = await import('/src/lib/env.ts');
        const supabaseModule = await import('/src/lib/supabaseClient.ts');
        const env = envModule.getAppEnv();
        const session = await withinProbe(supabaseModule.supabase.auth.getSession(), 12000);
        const accessToken = session.data.session?.access_token;
        const controller = new AbortController();
        const response = await withinProbe(fetch(env.supabaseUrl + '/functions/v1/list-pending-actions', {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            authorization: 'Bearer ' + accessToken,
            apikey: env.supabasePublishableKey,
          },
          body: JSON.stringify({}),
          signal: controller.signal,
        }), 12000, () => controller.abort());
        const text = await withinProbe(response.text(), 12000, () => controller.abort());
        return { ok: response.ok, status: response.status, text };
      } catch (error) {
        return { error: error?.name + ': ' + error?.message };
      }
    })()`);
    const apiClientFunctionProbe = await evaluate(client, `(async () => {
      try {
        const module = await import('/src/lib/apiClient.ts');
        const value = await module.callEdgeFunction('list-pending-actions', {});
        return { ok: true, value };
      } catch (error) {
        return {
          ok: false,
          name: error?.name ?? null,
          code: error?.code ?? null,
          outcome: error?.outcome ?? null,
          message: error?.message ?? String(error),
        };
      }
    })()`);
    state.browserEvents.push({
      kind: 'function-fetch-probe',
      raw: rawFunctionFetchProbe,
      exactManual: exactManualFunctionProbe,
      within: withinFunctionProbe,
      apiClient: apiClientFunctionProbe,
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
    await waitForText(client, '今日の情報を取得できませんでした', 8_000);
    scenarios.push({
      scenarioId: 'CF14-TODAY-REAL-BROWSER-ERROR',
      entryBoundary: 'real Chrome Today navigation with failing canonical read',
      visibleAssertion: 'the initial canonical Today read failure is rendered as a user-visible error state',
      screenshot: await screenshot(client, 'today-error.png'),
    });

    state.mode = 'consultation';
    partnerBrowser = await startChrome();
    partnerClient = new CdpClient(partnerBrowser.page.webSocketDebuggerUrl);
    await partnerClient.connect();
    await partnerClient.send('Page.enable');
    await seedMobileSession(partnerClient, partner);
    scenarios.push(await runRequestJourney(client, partnerClient));

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
      partnerUrl: partnerClient ? await evaluate(partnerClient, 'window.location.href').catch(() => null) : null,
      partnerBodyText: partnerClient ? await evaluate(partnerClient, 'document.body?.innerText ?? ""').catch(() => null) : null,
      requestCommands,
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
    partnerClient?.close();
    await Promise.all([stopChild(chrome?.child), stopChild(partnerBrowser?.child)]);
    await stopChild(vite);
    await stopServer(mockSupabase);
    for (const browser of [chrome, partnerBrowser].filter(Boolean)) {
      try {
        await rm(browser.userDataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      } catch (error) {
        console.warn(`[cf14-browser] Chrome profile cleanup did not complete: ${error.message}`);
      }
    }
  }
}

await main();
