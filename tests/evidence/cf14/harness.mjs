import assert from 'node:assert/strict';
import { AUTHORING_STATUSES, EVIDENCE_CLASSES } from './scenarios.mjs';

const evidenceClassSet = new Set(EVIDENCE_CLASSES);
const authoringStatusSet = new Set(AUTHORING_STATUSES);
const ALL_REQUIREMENTS = new Set(Array.from({ length: 112 }, (_, index) => `Q${index + 1}`));
const ACCEPTANCE_BLOCKING_STATUSES = new Set(['expected-failing', 'skeleton']);

export function validateScenarioManifest(scenarios) {
  assert.ok(Array.isArray(scenarios) && scenarios.length > 0, 'scenario manifest must not be empty');
  const ids = new Set();
  const covered = new Set();
  for (const scenario of scenarios) {
    assert.match(scenario.scenarioId ?? '', /^CF14-[A-Z0-9-]+$/, `invalid scenario id: ${scenario.scenarioId}`);
    assert.ok(!ids.has(scenario.scenarioId), `duplicate scenario id: ${scenario.scenarioId}`);
    ids.add(scenario.scenarioId);
    assert.ok(Array.isArray(scenario.requirementIds) && scenario.requirementIds.length > 0, `${scenario.scenarioId}: requirements required`);
    for (const requirementId of scenario.requirementIds) {
      assert.ok(ALL_REQUIREMENTS.has(requirementId), `${scenario.scenarioId}: unknown requirement ${requirementId}`);
      covered.add(requirementId);
    }
    assert.ok(typeof scenario.entryBoundary === 'string' && scenario.entryBoundary.length > 0, `${scenario.scenarioId}: entry boundary required`);
    assert.ok(typeof scenario.userVisibleAssertion === 'string' && scenario.userVisibleAssertion.length > 0, `${scenario.scenarioId}: user-visible assertion required`);
    assert.ok(Array.isArray(scenario.requiredEvidenceClasses) && scenario.requiredEvidenceClasses.length > 0, `${scenario.scenarioId}: evidence classes required`);
    for (const evidenceClass of scenario.requiredEvidenceClasses) {
      assert.ok(evidenceClassSet.has(evidenceClass), `${scenario.scenarioId}: unknown evidence class ${evidenceClass}`);
    }
    assert.ok(authoringStatusSet.has(scenario.status), `${scenario.scenarioId}: F1 status must be authoring/pending, never PASS`);
    if (ACCEPTANCE_BLOCKING_STATUSES.has(scenario.status)) {
      assert.ok(
        typeof scenario.expectedFailureReason === 'string' && scenario.expectedFailureReason.length > 0,
        `${scenario.scenarioId}: acceptance-blocking status requires an attributable failure reason`,
      );
    }
  }
  const missing = [...ALL_REQUIREMENTS].filter((id) => !covered.has(id));
  assert.deepEqual(missing, [], `requirements missing from CF-14 traceability: ${missing.join(', ')}`);
  return { scenarioCount: ids.size, requirementCount: covered.size };
}

export async function runRawLanguageCase(adapter, fixture) {
  assert.equal(typeof fixture.rawText, 'string', `${fixture.id}: rawText required`);
  assert.ok(fixture.rawText.trim().length > 0, `${fixture.id}: rawText must not be blank`);
  assert.ok(!Object.hasOwn(fixture, 'candidateJson'), `${fixture.id}: prebuilt candidate JSON is forbidden at raw-language entry`);
  assert.equal(typeof adapter?.parseNaturalLanguage, 'function', 'adapter.parseNaturalLanguage is required');
  const observed = await adapter.parseNaturalLanguage(fixture.rawText);
  assert.deepEqual(observed.intentKinds, fixture.expectedIntentKinds, `${fixture.id}: intent decomposition mismatch`);
  assert.deepEqual(observed.missingFields, fixture.expectedMissingOnly, `${fixture.id}: must ask only unresolved fields`);
  return observed;
}

export async function runResponseLossRetry({ invoke, operationId, body }) {
  assert.equal(typeof invoke, 'function', 'invoke adapter required');
  let firstError;
  try {
    await invoke({ operationId, body, simulateResponseLoss: true });
  } catch (error) {
    firstError = error;
  }
  assert.ok(firstError, 'first call must simulate response loss after server-side processing');
  assert.equal(firstError.code, 'SIMULATED_RESPONSE_LOSS');
  const retried = await invoke({ operationId, body, simulateResponseLoss: false });
  assert.equal(retried.replayed, true, 'retry must replay prior canonical result');
  assert.equal(retried.mutationCount, 1, 'response retry must not duplicate the canonical mutation');
  return retried;
}

export function validateRequestLifecycleFixtures(fixtures) {
  const terminalStates = new Set(['accepted', 'declined', 'expired', 'cancelled']);
  for (const fixture of fixtures) {
    assert.ok(fixture.id, 'fixture id required');
    assert.ok(fixture.initial?.attemptId, `${fixture.id}: attempt id required`);
    assert.ok(Number.isInteger(fixture.initial.revision) && fixture.initial.revision > 0, `${fixture.id}: initial revision required`);
    assert.ok(Number.isInteger(fixture.command?.expectedRevision), `${fixture.id}: expected revision required`);
    const expected = fixture.expected ?? {};
    assert.ok(expected.state || expected.errorCode, `${fixture.id}: expected state or error required`);
    if (expected.state) {
      assert.ok(Number.isInteger(expected.revision) && expected.revision >= fixture.initial.revision, `${fixture.id}: expected revision invalid`);
      if (expected.terminal === true) assert.ok(terminalStates.has(expected.state), `${fixture.id}: terminal state mismatch`);
    }
  }
  return fixtures.length;
}

export async function runBrowserStateScenario(adapter, cases) {
  assert.equal(typeof adapter?.observe, 'function', 'browser adapter.observe required');
  const evidence = [];
  for (const testCase of cases) {
    const observed = await adapter.observe(testCase.input);
    assert.equal(observed.visibleState, testCase.expectedVisibleState, `${testCase.id}: visible state mismatch`);
    if (testCase.mustContain) assert.match(observed.text, testCase.mustContain, `${testCase.id}: required user-visible text missing`);
    evidence.push({ id: testCase.id, observed });
  }
  return evidence;
}

export async function runBackReturnJourney(adapter, fixture) {
  for (const method of ['open', 'mutate', 'back', 'returnTo']) assert.equal(typeof adapter?.[method], 'function', `navigation adapter.${method} required`);
  const before = await adapter.open(fixture.start);
  await adapter.mutate(fixture.mutation);
  await adapter.back();
  const after = await adapter.returnTo(fixture.start);
  assert.equal(after.selectionKey, before.selectionKey, 'selection/context must survive back/return journey');
  assert.equal(after.scrollAnchor, before.scrollAnchor, 'scroll anchor must survive back/return journey');
  return after;
}

export async function runNurseryActualInput(adapter, fixture) {
  assert.match(fixture.mimeType ?? '', /^image\//, 'nursery fixture must be an image MIME type');
  assert.ok(!Object.hasOwn(fixture, 'candidateJson'), 'nursery actual-input fixture must not start from candidate JSON');
  const bytes = Buffer.from(fixture.imageBase64 ?? '', 'base64');
  assert.ok(bytes.length > 16, 'nursery fixture must contain actual image bytes');
  assert.equal(typeof adapter?.ingestImage, 'function', 'adapter.ingestImage required');
  const result = await adapter.ingestImage({ bytes, mimeType: fixture.mimeType, fileName: fixture.fileName });
  assert.deepEqual(result.stages, ['classify', 'ocr', 'ai', 'review'], 'actual input evidence must traverse classify/OCR/AI/review stages in order');
  assert.equal(result.mutatedBeforeConfirm, false, 'nursery intake must not finalize household data before confirmation');
  assert.ok(result.provenanceId, 'source provenance must be retained');
  if (Array.isArray(fixture.expectedSourceHints) && fixture.expectedSourceHints.length > 0) {
    assert.equal(typeof result.sourceText, 'string', `${fixture.id}: OCR/source text evidence required for representative image`);
    for (const hint of fixture.expectedSourceHints) {
      assert.ok(result.sourceText.includes(hint), `${fixture.id}: OCR/source evidence missing hint: ${hint}`);
    }
  }
  return result;
}

function assertProviderBoundary(result, expectedBoundary) {
  assert.equal(result.entryBoundary, expectedBoundary, `expected entry boundary ${expectedBoundary}`);
  assert.ok(result.providerEventId, 'provider event id required');
  assert.ok(result.userVisibleResult, 'user-visible result required');
  assert.ok(result.canonicalReadback, 'canonical readback required');
}

export async function runLineWebhookScenario(adapter, event) {
  assert.equal(typeof adapter?.receiveWebhook, 'function', 'LINE receiveWebhook adapter required');
  const result = await adapter.receiveWebhook(event);
  assertProviderBoundary(result, 'line-messaging-api');
  return result;
}

export async function runLinePostbackScenario(adapter, event) {
  assert.equal(typeof adapter?.receivePostback, 'function', 'LINE receivePostback adapter required');
  const result = await adapter.receivePostback(event);
  assertProviderBoundary(result, 'line-messaging-api');
  return result;
}

export async function runGoogleControlledProvider(adapter, event) {
  assert.equal(typeof adapter?.receiveProviderEvent, 'function', 'Google provider adapter required');
  const result = await adapter.receiveProviderEvent(event);
  assertProviderBoundary(result, 'google-calendar-provider');
  return result;
}

export async function runCrossChannelRace({ line, pwa, readCanonical }) {
  assert.equal(typeof line, 'function', 'line transport action required');
  assert.equal(typeof pwa, 'function', 'pwa transport action required');
  assert.equal(typeof readCanonical, 'function', 'canonical readback required');
  const settled = await Promise.allSettled([line(), pwa()]);
  const canonical = await readCanonical();
  assert.ok(canonical?.revision, 'canonical revision required after race');
  assert.ok(canonical?.terminalState, 'canonical terminal state required after race');
  const observations = settled.map((entry, index) => ({ channel: index === 0 ? 'line' : 'pwa', status: entry.status }));
  assert.deepEqual(observations.map((entry) => entry.channel), ['line', 'pwa']);
  return { settled, canonical, observations };
}

export async function runClockBoundaryScenario(adapter, fixtures) {
  assert.equal(typeof adapter?.evaluateClock, 'function', 'clock adapter.evaluateClock required');
  const evidence = [];
  for (const fixture of fixtures) {
    assert.match(fixture.at ?? '', /\+09:00$/, `${fixture.id}: clock fixture must use explicit JST offset`);
    assert.ok(['weekday', 'weekend', 'holiday'].includes(fixture.dayType), `${fixture.id}: invalid day type`);
    assert.ok(['morning', 'evening'].includes(fixture.deliveryKind), `${fixture.id}: invalid delivery kind`);
    assert.equal(typeof fixture.expectedShouldDeliver, 'boolean', `${fixture.id}: expected delivery boolean required`);
    const observed = await adapter.evaluateClock({
      at: fixture.at,
      dayType: fixture.dayType,
      deliveryKind: fixture.deliveryKind,
    });
    assert.equal(observed.localAt, fixture.at, `${fixture.id}: adapter must preserve explicit local clock evidence`);
    assert.equal(observed.deliveryKind, fixture.deliveryKind, `${fixture.id}: delivery kind mismatch`);
    assert.equal(observed.shouldDeliver, fixture.expectedShouldDeliver, `${fixture.id}: boundary result mismatch`);
    evidence.push({ id: fixture.id, observed });
  }
  return evidence;
}

export async function runWholeDayScenario(steps, adapters) {
  const evidence = [];
  for (const step of steps) {
    const adapter = adapters[step.channel];
    assert.equal(typeof adapter, 'function', `missing ${step.channel} adapter for ${step.id}`);
    const observed = await adapter(step);
    assert.equal(observed.stepId, step.id, `${step.id}: adapter must preserve scenario step identity`);
    evidence.push({ ...step, observed });
  }
  return evidence;
}

export function assessEvidence(scenarios, evidenceRecords, { strict = false } = {}) {
  const records = Array.isArray(evidenceRecords) ? evidenceRecords : [];
  return scenarios.map((scenario) => {
    const missingEvidenceClasses = scenario.requiredEvidenceClasses.filter((required) =>
      !records.some((record) => record.scenarioId === scenario.scenarioId && record.evidenceClass === required && record.status === 'PASS'),
    );
    const acceptanceBlocked = ACCEPTANCE_BLOCKING_STATUSES.has(scenario.status);
    const result = acceptanceBlocked
      ? strict ? 'FAIL' : 'PENDING'
      : missingEvidenceClasses.length === 0
        ? 'PASS'
        : strict ? 'FAIL' : 'PENDING';
    return {
      scenarioId: scenario.scenarioId,
      requirementIds: scenario.requirementIds,
      result,
      missingEvidenceClasses,
      acceptanceBlocked,
      blockingReason: acceptanceBlocked ? scenario.expectedFailureReason : null,
    };
  });
}
