import assert from 'node:assert/strict';
import test from 'node:test';
import {
  assessEvidence,
  runBackReturnJourney,
  runBrowserStateScenario,
  runCrossChannelRace,
  runGoogleControlledProvider,
  runLinePostbackScenario,
  runLineWebhookScenario,
  runNurseryActualInput,
  runRawLanguageCase,
  runResponseLossRetry,
  runWholeDayScenario,
  validateRequestLifecycleFixtures,
  validateScenarioManifest,
} from './harness.mjs';
import { nurseryActualImageFixture, rawLanguageCorpus, requestLifecycleFixtures, wholeDaySkeleton } from './fixtures.mjs';
import { cf14Scenarios } from './scenarios.mjs';

test('manifest traces all Q1-Q112 without allowing F1 PASS status', () => {
  assert.deepEqual(validateScenarioManifest(cf14Scenarios), { scenarioCount: cf14Scenarios.length, requirementCount: 112 });
  assert.equal(cf14Scenarios.some((scenario) => scenario.status === 'PASS'), false);
});

test('Q70/Q71 corpus begins from raw language rather than prebuilt candidate JSON', async () => {
  const byText = new Map(rawLanguageCorpus.map((fixture) => [fixture.rawText, fixture]));
  const adapter = {
    async parseNaturalLanguage(rawText) {
      const fixture = byText.get(rawText);
      return { intentKinds: fixture.expectedIntentKinds, missingFields: fixture.expectedMissingOnly };
    },
  };
  for (const fixture of rawLanguageCorpus) await runRawLanguageCase(adapter, fixture);
  await assert.rejects(
    () => runRawLanguageCase(adapter, { ...rawLanguageCorpus[0], candidateJson: { prebuilt: true } }),
    /candidate JSON is forbidden/,
  );
});

test('response loss retry proves one canonical mutation and an idempotent replay', async () => {
  const receipts = new Map();
  let mutationCount = 0;
  const invoke = async ({ operationId, body, simulateResponseLoss }) => {
    let receipt = receipts.get(operationId);
    if (!receipt) {
      mutationCount += 1;
      receipt = { canonicalId: `request-${mutationCount}`, bodyHash: JSON.stringify(body) };
      receipts.set(operationId, receipt);
    } else {
      assert.equal(receipt.bodyHash, JSON.stringify(body));
    }
    if (simulateResponseLoss) throw Object.assign(new Error('lost after commit'), { code: 'SIMULATED_RESPONSE_LOSS' });
    return { canonicalId: receipt.canonicalId, replayed: true, mutationCount };
  };
  const result = await runResponseLossRetry({ invoke, operationId: 'op-1', body: { action: 'accept' } });
  assert.equal(result.canonicalId, 'request-1');
});

test('Request lifecycle fixture framework includes terminal, expiry and stale revision cases', () => {
  assert.equal(validateRequestLifecycleFixtures(requestLifecycleFixtures), 3);
  assert.ok(requestLifecycleFixtures.some((fixture) => fixture.expected.errorCode === 'ATTEMPT_EXPIRED'));
  assert.ok(requestLifecycleFixtures.some((fixture) => fixture.expected.errorCode === 'STALE_REVISION'));
});

test('browser-state and back/return harnesses assert user-observable state, not source strings', async () => {
  const states = await runBrowserStateScenario(
    { observe: async (input) => ({ visibleState: input, text: `画面状態: ${input}` }) },
    [
      { id: 'loading', input: 'loading', expectedVisibleState: 'loading', mustContain: /loading/ },
      { id: 'error', input: 'error', expectedVisibleState: 'error', mustContain: /error/ },
      { id: 'stale', input: 'stale', expectedVisibleState: 'stale', mustContain: /stale/ },
    ],
  );
  assert.equal(states.length, 3);

  const state = { selectionKey: 'task-7', scrollAnchor: 'today-normal-3' };
  const after = await runBackReturnJourney(
    {
      open: async () => ({ ...state }),
      mutate: async () => undefined,
      back: async () => undefined,
      returnTo: async () => ({ ...state }),
    },
    { start: '/today?task=task-7', mutation: { kind: 'open-detail' } },
  );
  assert.deepEqual(after, state);
});

test('Nursery harness requires actual image bytes plus OCR/classify/AI/review evidence before mutation', async () => {
  const sourceText = nurseryActualImageFixture.expectedSourceHints.join('\n');
  const observed = await runNurseryActualInput(
    {
      ingestImage: async ({ bytes }) => ({
        stages: ['classify', 'ocr', 'ai', 'review'],
        mutatedBeforeConfirm: false,
        provenanceId: `source-${bytes.length}`,
        sourceText,
      }),
    },
    nurseryActualImageFixture,
  );
  assert.match(observed.provenanceId, /^source-/);
  assert.ok(nurseryActualImageFixture.expectedSourceHints.every((hint) => observed.sourceText.includes(hint)));
  await assert.rejects(
    () => runNurseryActualInput({ ingestImage: async () => ({}) }, { ...nurseryActualImageFixture, candidateJson: {} }),
    /must not start from candidate JSON/,
  );
  await assert.rejects(
    () => runNurseryActualInput(
      {
        ingestImage: async () => ({
          stages: ['classify', 'ocr', 'ai', 'review'],
          mutatedBeforeConfirm: false,
          provenanceId: 'source-without-ocr',
          sourceText: '',
        }),
      },
      nurseryActualImageFixture,
    ),
    /OCR\/source evidence missing hint/,
  );
});

test('LINE webhook/postback harness rejects DB-only evidence and requires Messaging API boundary', async () => {
  const providerResult = {
    entryBoundary: 'line-messaging-api',
    providerEventId: 'line-event-1',
    userVisibleResult: '確認してください',
    canonicalReadback: { state: 'pending' },
  };
  assert.equal((await runLineWebhookScenario({ receiveWebhook: async () => providerResult }, { type: 'message' })).providerEventId, 'line-event-1');
  assert.equal((await runLinePostbackScenario({ receivePostback: async () => ({ ...providerResult, providerEventId: 'postback-1' }) }, { type: 'postback' })).providerEventId, 'postback-1');
  await assert.rejects(
    () => runLineWebhookScenario({ receiveWebhook: async () => ({ ...providerResult, entryBoundary: 'db-rpc' }) }, {}),
    /expected entry boundary line-messaging-api/,
  );
});

test('Google controlled-provider harness requires provider boundary instead of DB-only projection', async () => {
  const event = await runGoogleControlledProvider(
    {
      receiveProviderEvent: async () => ({
        entryBoundary: 'google-calendar-provider',
        providerEventId: 'gcal-evt-1',
        userVisibleResult: '日時変更の確認',
        canonicalReadback: { reviewState: 'candidate' },
      }),
    },
    { kind: 'updated' },
  );
  assert.equal(event.providerEventId, 'gcal-evt-1');
  await assert.rejects(
    () => runGoogleControlledProvider({ receiveProviderEvent: async () => ({ ...event, entryBoundary: 'db-rpc' }) }, {}),
    /expected entry boundary google-calendar-provider/,
  );
});

test('LINE/PWA race harness records both transports and one canonical readback', async () => {
  const result = await runCrossChannelRace({
    line: async () => ({ transport: 'line', status: 'accepted' }),
    pwa: async () => { throw Object.assign(new Error('stale'), { code: 'STALE_REVISION' }); },
    readCanonical: async () => ({ revision: 8, terminalState: 'accepted' }),
  });
  assert.deepEqual(result.observations.map((entry) => entry.channel), ['line', 'pwa']);
  assert.equal(result.canonical.terminalState, 'accepted');
});

test('whole-day orchestration skeleton preserves ordered cross-channel steps', async () => {
  const evidence = await runWholeDayScenario(wholeDaySkeleton, {
    line: async (step) => ({ stepId: step.id, visible: true }),
    pwa: async (step) => ({ stepId: step.id, visible: true }),
  });
  assert.deepEqual(evidence.map((entry) => entry.id), wholeDaySkeleton.map((step) => step.id));
});

test('strict F2 evidence assessment fails missing provider/device boundaries instead of treating skips as PASS', () => {
  const authoring = assessEvidence(cf14Scenarios, [], { strict: false });
  assert.ok(authoring.every((result) => result.result === 'PENDING'));
  const strict = assessEvidence(cf14Scenarios, [], { strict: true });
  assert.ok(strict.every((result) => result.result === 'FAIL'));
});
