import assert from 'node:assert/strict';
import { EVIDENCE_CLASSES } from './scenarios.mjs';

const evidenceClassSet = new Set(EVIDENCE_CLASSES);
const PASS = 'PASS';

function assertNonEmptyString(value, label) {
  assert.equal(typeof value, 'string', `${label} must be a string`);
  assert.ok(value.trim().length > 0, `${label} must not be blank`);
}

function assertStringArray(value, label, { min = 1 } = {}) {
  assert.ok(Array.isArray(value), `${label} must be an array`);
  assert.ok(value.length >= min, `${label} requires at least ${min} item(s)`);
  value.forEach((entry, index) => assertNonEmptyString(entry, `${label}[${index}]`));
}

function assertTimestamp(value, label) {
  assertNonEmptyString(value, label);
  assert.ok(/(?:Z|[+-]\d{2}:\d{2})$/.test(value), `${label} must include an explicit timezone`);
  assert.ok(Number.isFinite(Date.parse(value)), `${label} must be a valid timestamp`);
}

function assertOrderedStages(stages, requiredStages, label) {
  assert.ok(Array.isArray(stages), `${label} must be an array`);
  let cursor = -1;
  for (const required of requiredStages) {
    const next = stages.indexOf(required, cursor + 1);
    assert.ok(next > cursor, `${label} must include ${required} in order`);
    cursor = next;
  }
}

function assertEnvironment(environment, label) {
  assert.ok(environment && typeof environment === 'object' && !Array.isArray(environment), `${label} must be an object`);
  assertNonEmptyString(environment.browser, `${label}.browser`);
  assertNonEmptyString(environment.viewport, `${label}.viewport`);
}

export function validatePassEvidenceRecord(record, { exactHead } = {}) {
  assert.ok(record && typeof record === 'object' && !Array.isArray(record), 'PASS evidence record must be an object');
  assert.equal(record.status, PASS, 'validatePassEvidenceRecord accepts PASS records only');
  assert.match(record.scenarioId ?? '', /^CF14-[A-Z0-9-]+$/, 'PASS evidence requires a CF14 scenarioId');
  assert.ok(evidenceClassSet.has(record.evidenceClass), `unknown evidence class: ${record.evidenceClass}`);
  assert.match(record.exactHead ?? '', /^[0-9a-f]{40}$/, 'PASS evidence requires a 40-character exactHead');
  if (exactHead) assert.equal(record.exactHead, exactHead, 'PASS evidence must be bound to the payload exactHead');
  assertNonEmptyString(record.source, 'PASS evidence source/artifact reference');
  assertTimestamp(record.capturedAt, 'PASS evidence capturedAt');

  const details = record.details;
  assert.ok(details && typeof details === 'object' && !Array.isArray(details), 'PASS evidence requires details{}');
  assertNonEmptyString(details.entryBoundary, 'details.entryBoundary');

  switch (record.evidenceClass) {
    case 'unit-domain':
      assertStringArray(details.assertions, 'details.assertions');
      break;
    case 'db-rpc':
      assertNonEmptyString(details.canonicalReadbackArtifact, 'details.canonicalReadbackArtifact');
      assertStringArray(details.assertions, 'details.assertions');
      break;
    case 'edge-api':
      assertNonEmptyString(details.requestArtifact, 'details.requestArtifact');
      assertNonEmptyString(details.responseArtifact, 'details.responseArtifact');
      assertStringArray(details.assertions, 'details.assertions');
      break;
    case 'browser':
      assertNonEmptyString(details.interactionArtifact, 'details.interactionArtifact');
      assertStringArray(details.interactionSteps, 'details.interactionSteps');
      assertStringArray(details.visibleAssertions, 'details.visibleAssertions');
      assertEnvironment(details.environment, 'details.environment');
      break;
    case 'line-transport':
      assertNonEmptyString(details.providerEventId, 'details.providerEventId');
      assertNonEmptyString(details.requestArtifact, 'details.requestArtifact');
      assertNonEmptyString(details.replyArtifact, 'details.replyArtifact');
      assertNonEmptyString(details.userVisibleResult, 'details.userVisibleResult');
      break;
    case 'google-provider':
      assertNonEmptyString(details.providerEventId, 'details.providerEventId');
      assertNonEmptyString(details.providerOperation, 'details.providerOperation');
      assertNonEmptyString(details.providerResponseArtifact, 'details.providerResponseArtifact');
      assertNonEmptyString(details.userVisibleResult, 'details.userVisibleResult');
      break;
    case 'image-ocr-ai':
      assertNonEmptyString(details.inputArtifact, 'details.inputArtifact');
      assertOrderedStages(details.stages, ['classify', 'ocr', 'ai', 'review'], 'details.stages');
      assertNonEmptyString(details.provenanceId, 'details.provenanceId');
      assertNonEmptyString(details.reviewArtifact, 'details.reviewArtifact');
      assertStringArray(details.visibleAssertions, 'details.visibleAssertions');
      break;
    case 'physical-iphone-manual':
      assertNonEmptyString(details.deviceModel, 'details.deviceModel');
      assertNonEmptyString(details.osVersion, 'details.osVersion');
      assert.ok(['installed-pwa', 'safari'].includes(details.surface), 'details.surface must be installed-pwa or safari');
      assertStringArray(details.interactionSteps, 'details.interactionSteps');
      assertStringArray(details.screenshotArtifacts, 'details.screenshotArtifacts');
      assertStringArray(details.visibleAssertions, 'details.visibleAssertions');
      break;
    case 'cross-channel-concurrency':
      assertNonEmptyString(details.lineArtifact, 'details.lineArtifact');
      assertNonEmptyString(details.pwaArtifact, 'details.pwaArtifact');
      assertNonEmptyString(details.canonicalReadbackArtifact, 'details.canonicalReadbackArtifact');
      assert.ok(Number.isFinite(details.concurrencyWindowMs) && details.concurrencyWindowMs >= 0, 'details.concurrencyWindowMs must be a non-negative number');
      assertStringArray(details.visibleAssertions, 'details.visibleAssertions');
      break;
    case 'whole-day-scenario': {
      assert.ok(Array.isArray(details.timeline) && details.timeline.length >= 3, 'details.timeline requires at least three clocked steps');
      let previousTimestamp = -Infinity;
      for (const [index, step] of details.timeline.entries()) {
        assert.ok(step && typeof step === 'object' && !Array.isArray(step), `details.timeline[${index}] must be an object`);
        assertNonEmptyString(step.step, `details.timeline[${index}].step`);
        assertNonEmptyString(step.channel, `details.timeline[${index}].channel`);
        assertTimestamp(step.at, `details.timeline[${index}].at`);
        const timestamp = Date.parse(step.at);
        assert.ok(timestamp > previousTimestamp, `details.timeline[${index}].at must be later than the previous step`);
        previousTimestamp = timestamp;
      }
      assertStringArray(details.visibleAssertions, 'details.visibleAssertions');
      break;
    }
    default:
      assert.fail(`unsupported evidence class: ${record.evidenceClass}`);
  }

  return record;
}

export function validateEvidenceRecords(scenarios, records, { exactHead } = {}) {
  assert.ok(Array.isArray(records), 'evidence records must be an array');
  const scenarioById = new Map(scenarios.map((scenario) => [scenario.scenarioId, scenario]));
  let passCount = 0;

  records.forEach((record, index) => {
    if (record?.status !== PASS) return;
    try {
      validatePassEvidenceRecord(record, { exactHead });
      const scenario = scenarioById.get(record.scenarioId);
      assert.ok(scenario, `unknown scenarioId: ${record.scenarioId}`);
      assert.ok(
        scenario.requiredEvidenceClasses.includes(record.evidenceClass),
        `${record.scenarioId}: ${record.evidenceClass} is not a required evidence class`,
      );
      passCount += 1;
    } catch (error) {
      error.message = `records[${index}]: ${error.message}`;
      throw error;
    }
  });

  return { passCount };
}
