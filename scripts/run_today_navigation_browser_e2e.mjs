import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const APP_URL = 'http://127.0.0.1:4173/today';
const MOCK_SUPABASE_URL = 'http://127.0.0.1:54321';
const ARTIFACT_DIR = path.resolve('artifacts/today-navigation-browser');
const SOURCE_HEAD = process.env.GITHUB_HEAD_SHA || process.env.GITHUB_SHA || 'local';

const tokyoDate = (date = new Date()) => new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit',
}).format(date);
const TODAY = tokyoDate();
const TOMORROW = tokyoDate(new Date(Date.now() + 24 * 60 * 60 * 1000));

const membership = {
  household_id: 'household-lane-d', user_id: 'user-lane-d', member_role: 'adult', family_role: 'papa',
  joined_at: '2026-01-01T00:00:00Z',
};
const household = {
  id: membership.household_id, name: 'Lane D Browser Household', timezone: 'Asia/Tokyo',
  evening_routine_setup_completed_at: '2026-01-01T00:00:00Z',
  dropoff_pickup_setup_completed_at: '2026-01-01T00:00:00Z',
  morning_preparation_setup_completed_at: '2026-01-01T00:00:00Z',
  connections_setup_completed_at: '2026-01-01T00:00:00Z',
  notification_preferences_setup_completed_at: '2026-01-01T00:00:00Z',
  onboarding_preview_completed_at: '2026-01-01T00:00:00Z',
};
const task = {
  id: 'task-lane-d-browser', household_id: household.id, task_definition_id: null, recurrence_rule_id: null,
  origin: 'manual', title: 'ブラウザ確認タスク', category: 'other', routine_phase: 'anytime', scheduled_date: TODAY,
  due_at: null, calendar_ends_at: null, calendar_visibility: 'hidden', task_kind: 'generic_once',
  planned_assignee_id: membership.user_id, assignment_mode: 'person', completion_mode: 'whole', status: 'todo',
  actual_completed_by_id: null, completed_at: null, attention_state: 'active', waiting_note: null,
  next_check_at: null, revision: 1, task_definitions: null,
};
const state = { initialBriefDelayMs: 800, requests: [] };

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
    try { return execFileSync('which', [candidate], { encoding: 'utf8' }).trim(); } catch { /* next */ }
  }
  throw new Error('Today/navigation browser E2E requires Chrome/Chromium on the runner.');
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
        Promise.resolve(handler(message.params ?? {})).catch((error) => console.error('[today-browser]', error));
      }
    });
  }
  on(method, handler) { this.listeners.set(method, [...(this.listeners.get(method) ?? []), handler]); }
  send(method, params = {}) {
    assert.ok(this.socket?.readyState === WebSocket.OPEN, `CDP must be open before ${method}`);
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
  return {
    tasks: [{ task_id: task.id, title: task.title }],
    own_task_groups: { morning: [], daytime: [{ task_id: task.id, title: task.title }], evening: [], optional: [] },
    urgent_actions: [], exceptions: [], waiting_checks: [], carryovers: [], carryover: [], already_handled: [],
    active_infos: [], handovers: [], shopping: [],
    schedule: [{
      kind: 'family_event', family_event_id: 'event-lane-d', occurrence_key: null, title: '15時 保育園面談',
      is_all_day: false, starts_at: `${TODAY}T06:00:00Z`, ends_at: `${TODAY}T06:30:00Z`,
      all_day_start: null, all_day_end_exclusive: null,
    }],
    partner_summary: { open_assigned: 0, waiting: 0, completed_today: 0, critical_items: [] },
    reconciliation: { sessions: [], remaining_count: 0, actionable: false },
    tomorrow_impact: {
      local_date: TOMORROW, task_count: 1, schedule_count: 0, carryover_count: 0, impact_count: 1,
      tasks: [{ task_id: 'tomorrow-lane-d', title: '明日の着替え準備' }], schedule: [], carryovers: [],
    },
    morning_summary: { completed_count: 0, total_count: 0 },
  };
}

async function fulfillRequest(client, { requestId, request }) {
  const url = new URL(request.url);
  state.requests.push({ method: request.method, pathname: url.pathname });
  if (request.method === 'OPTIONS') {
    await client.send('Fetch.fulfillRequest', { requestId, ...noContentResponse() });
    return;
  }

  const pathname = url.pathname;
  let response;
  if (pathname === '/rest/v1/household_members') {
    response = url.searchParams.has('user_id') && !url.searchParams.has('household_id')
      ? jsonResponse(membership)
      : jsonResponse([membership]);
  } else if (pathname === '/rest/v1/households') {
    response = jsonResponse(household);
  } else if (pathname === '/rest/v1/profiles') {
    response = jsonResponse([{ user_id: membership.user_id, display_name: 'パパ' }]);
  } else if (pathname === '/rest/v1/rpc/get_my_daily_brief') {
    if (state.initialBriefDelayMs) await sleep(state.initialBriefDelayMs);
    response = jsonResponse(dailyBrief());
  } else if (pathname === '/rest/v1/task_instances') {
    response = jsonResponse([task]);
  } else if (pathname === '/rest/v1/task_subtask_instances' || pathname === '/rest/v1/task_execution_targets') {
    response = jsonResponse([]);
  } else if (pathname === '/rest/v1/requests' || pathname === '/rest/v1/handovers' || pathname === '/rest/v1/shopping_items') {
    response = jsonResponse([]);
  } else if (pathname === '/functions/v1/list-pending-actions') {
    response = jsonResponse([]);
  } else if (pathname === '/auth/v1/user') {
    response = jsonResponse({ id: membership.user_id, aud: 'authenticated', role: 'authenticated' });
  } else if (pathname.startsWith('/rest/v1/')) {
    response = jsonResponse([]);
  } else if (pathname.startsWith('/functions/v1/')) {
    response = jsonResponse({});
  } else {
    response = jsonResponse({ message: `Unhandled browser fixture path ${pathname}` }, 404);
  }
  await client.send('Fetch.fulfillRequest', { requestId, ...response });
}

async function evaluate(client, expression) {
  const result = await client.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || `Browser evaluate failed: ${expression}`);
  return result.result?.value;
}

const waitForText = (client, text, timeoutMs = 10_000) => waitFor(
  () => evaluate(client, `document.body?.innerText.includes(${JSON.stringify(text)}) === true`),
  { timeoutMs, label: `text ${JSON.stringify(text)}` },
);
const waitForPath = (client, pathname, timeoutMs = 10_000) => waitFor(
  () => evaluate(client, `window.location.pathname === ${JSON.stringify(pathname)}`),
  { timeoutMs, label: `path ${pathname}` },
);

async function screenshot(client, filename) {
  const { data } = await client.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  const target = path.join(ARTIFACT_DIR, filename);
  await writeFile(target, Buffer.from(data, 'base64'));
  return path.relative(process.cwd(), target);
}

async function navigate(client, url) {
  await client.send('Page.navigate', { url });
  await waitFor(() => evaluate(client, `document.readyState === 'complete' || document.readyState === 'interactive'`), {
    timeoutMs: 10_000, label: `navigation ${url}`,
  });
}

async function startVite() {
  const child = spawn(process.platform === 'win32' ? 'npm.cmd' : 'npm', [
    'run', 'dev', '-w', 'apps/web', '--', '--host', '127.0.0.1', '--port', '4173', '--strictPort',
  ], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      VITE_SUPABASE_URL: MOCK_SUPABASE_URL,
      VITE_SUPABASE_PUBLISHABLE_KEY: 'lane-d-browser-key',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', (chunk) => { output += String(chunk); });
  child.stderr.on('data', (chunk) => { output += String(chunk); });
  child.on('exit', (code) => { if (code) console.error(`[today-browser] Vite exited ${code}\n${output}`); });
  await waitFor(async () => {
    try { return (await fetch('http://127.0.0.1:4173/')).ok; } catch { return false; }
  }, { timeoutMs: 20_000, intervalMs: 100, label: 'Vite' });
  return child;
}

async function startChrome() {
  const chromePath = findChrome();
  const userDataDir = await mkdtemp(path.join(os.tmpdir(), 'today-navigation-browser-'));
  const child = spawn(chromePath, [
    '--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--no-first-run',
    '--disable-default-apps', '--disable-background-networking', '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`, 'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  const activePortFile = path.join(userDataDir, 'DevToolsActivePort');
  const port = await waitFor(async () => {
    if (!existsSync(activePortFile)) return null;
    const [line] = (await readFile(activePortFile, 'utf8')).trim().split(/\r?\n/);
    return Number(line) || null;
  }, { timeoutMs: 10_000, label: 'Chrome DevTools port' });
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
    client.on('Fetch.requestPaused', (params) => fulfillRequest(client, params));
    await client.send('Page.enable');
    await client.send('Runtime.enable');
    await client.send('Fetch.enable', { patterns: [{ urlPattern: `${MOCK_SUPABASE_URL}/*`, requestStage: 'Request' }] });
    await client.send('Emulation.setDeviceMetricsOverride', { width: 393, height: 852, deviceScaleFactor: 3, mobile: true });

    const session = {
      access_token: 'lane-d-access-token', token_type: 'bearer', expires_in: 86_400,
      expires_at: Math.floor(Date.now() / 1000) + 86_400, refresh_token: 'lane-d-refresh-token',
      user: {
        id: membership.user_id, aud: 'authenticated', role: 'authenticated', email: 'lane-d@example.test',
        app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z',
      },
    };
    await client.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `localStorage.setItem('sb-127-auth-token', ${JSON.stringify(JSON.stringify(session))});`,
    });

    const browserVersion = await client.send('Browser.getVersion');
    const scenarios = [];
    await navigate(client, APP_URL);

    await waitForText(client, '読み込み中…', 8_000);
    assert.equal(await evaluate(client, `document.body.innerText.includes('今日は確認が必要な項目はありません')`), false);
    scenarios.push({ id: 'CF03-loading', assertion: 'Loading is visible and Empty is not rendered during the unresolved canonical read' });

    await waitForText(client, task.title, 12_000);
    for (const text of ['要対応 0', '残り 1', '待ち 0', '明日影響 1', '明日の着替え準備']) await waitForText(client, text);
    assert.equal(await evaluate(client, 'document.title'), 'おうちノート');
    scenarios.push({
      id: 'CF02-CF04-CF16-ready',
      assertion: 'Real mobile Chrome renders one DailyBrief-backed Today flow, four first-flow keys, tomorrow impact, and おうちノート identity',
      screenshot: await screenshot(client, 'today-ready.png'),
    });

    await evaluate(client, `document.body.style.minHeight='2600px'; window.scrollTo(0, 640);`);
    await waitFor(() => evaluate(client, 'window.scrollY >= 600'), { label: 'Today scroll position' });
    assert.equal(await evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find((item) => item.getAttribute('aria-label') === '追加する');
      if (!button) return false; button.click(); return true;
    })()`), true);
    await waitForText(client, '追加するもの');
    assert.equal(await evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find((item) => item.textContent?.includes('おうちコンシェルジュ'));
      if (!button) return false; button.click(); return true;
    })()`), true);
    await waitForPath(client, '/concierge');
    await waitForText(client, 'おうちコンシェルジュ');

    assert.equal(await evaluate(client, `(() => {
      const textarea = document.querySelector('textarea'); if (!textarea) return false;
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(textarea, '金曜のお迎えをお願いしたい');
      textarea.dispatchEvent(new Event('input', { bubbles: true })); return true;
    })()`), true);
    await waitFor(() => evaluate(client, `sessionStorage.getItem('family-ops:concierge-draft') === '金曜のお迎えをお願いしたい'`), { label: 'Concierge draft persistence' });

    assert.equal(await evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find((item) => item.textContent?.includes('戻る'));
      if (!button) return false; button.click(); return true;
    })()`), true);
    await waitForPath(client, '/today');
    await waitFor(() => evaluate(client, 'window.scrollY >= 600'), { label: 'app Back scroll restoration' });
    scenarios.push({ id: 'CF13-app-back', assertion: 'App Back returns to Today and restores the prior scroll position' });

    await evaluate(client, `(() => {
      const button = [...document.querySelectorAll('button')].find((item) => item.getAttribute('aria-label') === '追加する');
      button?.click();
    })()`);
    await waitForText(client, '追加するもの');
    await evaluate(client, `([...document.querySelectorAll('button')].find((item) => item.textContent?.includes('おうちコンシェルジュ')))?.click()`);
    await waitForPath(client, '/concierge');
    await waitFor(() => evaluate(client, `document.querySelector('textarea')?.value === '金曜のお迎えをお願いしたい'`), { label: 'draft reopened' });
    await evaluate(client, 'history.back()');
    await waitForPath(client, '/today');
    await waitFor(() => evaluate(client, 'window.scrollY >= 600'), { label: 'browser Back scroll restoration' });
    scenarios.push({
      id: 'CF13-browser-back-draft',
      assertion: 'Reopening Concierge restores the draft, and browser Back returns to the same Today scroll state',
      screenshot: await screenshot(client, 'today-after-browser-back.png'),
    });

    const evidence = {
      status: 'PASS', sourceHead: SOURCE_HEAD, capturedAt: new Date().toISOString(),
      browser: { product: browserVersion.product, userAgent: browserVersion.userAgent, viewport: '393x852', executable: chrome.chromePath },
      scenarios, requestCount: state.requests.length,
    };
    await writeFile(path.join(ARTIFACT_DIR, 'evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    console.log(`[today-browser] PASS ${scenarios.length} scenarios on ${browserVersion.product}`);
  } finally {
    client?.close();
    await stopChild(chrome?.child);
    await stopChild(vite);
    if (chrome?.userDataDir) await rm(chrome.userDataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
}

await main();
