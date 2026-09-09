import assert from 'node:assert/strict';
import test from 'node:test';
import { validateEvidenceRecords, validatePassEvidenceRecord } from './evidence-records.mjs';
import { cf14Scenarios, EVIDENCE_CLASSES } from './scenarios.mjs';

const HEAD = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const detailByClass = {
  'unit-domain': {
    entryBoundary: 'domain function',
    assertions: ['terminal state is preserved'],
  },
  'db-rpc': {
    entryBoundary: 'canonical RPC',
    canonicalReadbackArtifact: 'artifact://db/readback.json',
    assertions: ['revision advanced once'],
  },
  'edge-api': {
    entryBoundary: 'authenticated Edge endpoint',
    requestArtifact: 'artifact://edge/request.json',
    responseArtifact: 'artifact://edge/response.json',
    assertions: ['stale mutation failed closed'],
  },
  browser: {
    entryBoundary: 'rendered PWA route',
    interactionArtifact: 'artifact://browser/trace.zip',
    interactionSteps: ['open Today', 'tap item', 'return to Today'],
    visibleAssertions: ['selected item is still visible after return'],
    environment: { browser: 'Mobile Safari 26.6', viewport: '393x852' },
  },
  'line-transport': {
    entryBoundary: 'LINE Messaging API webhook',
    providerEventId: 'line-event-1',
    requestArtifact: 'artifact://line/webhook.json',
    replyArtifact: 'artifact://line/reply.json',
    userVisibleResult: 'お迎えの依頼を確認してください',
  },
  'google-provider': {
    entryBoundary: 'Google Calendar provider response',
    providerEventId: 'google-event-1',
    providerOperation: 'updated',
    providerResponseArtifact: 'artifact://google/provider-response.json',
    userVisibleResult: 'Google側の日時変更を確認してください',
  },
  'image-ocr-ai': {
    entryBoundary: 'raw nursery image intake',
    inputArtifact: 'artifact://nursery/source.png',
    stages: ['classify', 'ocr', 'ai', 'review'],
    provenanceId: 'source-1',
    reviewArtifact: 'artifact://nursery/review.png',
    visibleAssertions: ['source page and extracted date are both visible before confirmation'],
  },
  'physical-iphone-manual': {
    entryBoundary: 'physical iPhone installed PWA',
    deviceModel: 'iPhone 16',
    osVersion: 'iOS 26.6',
    surface: 'installed-pwa',
    interactionSteps: ['launch PWA', 'open Today', 'expand task', 'return from detail'],
    screenshotArtifacts: ['artifact://iphone/today.png', 'artifact://iphone/return.png'],
    visibleAssertions: ['expanded content is not clipped by bottom navigation'],
  },
  'cross-channel-concurrency': {
    entryBoundary: 'actual LINE and PWA commands against one revision',
    lineArtifact: 'artifact://race/line.json',
    pwaArtifact: 'artifact://race/pwa.json',
    canonicalReadbackArtifact: 'artifact://race/readback.json',
    concurrencyWindowMs: 74,
    visibleAssertions: ['winner is visible in both channels and stale loser does not overwrite it'],
  },
  'whole-day-scenario': {
    entryBoundary: 'clock-controlled family day journey',
    timeline: [
      { step: 'morning brief', channel: 'line', at: '2026-09-10T06:30:00+09:00' },
      { step: 'daytime change', channel: 'pwa', at: '2026-09-10T12:10:00+09:00' },
      { step: 'evening reconciliation', channel: 'line', at: '2026-09-10T20:30:00+09:00' },
    ],
    visibleAssertions: ['morning context, daytime change and evening result remain coherent'],
  },
};

function record(evidenceClass, overrides = {}) {
  return {
    scenarioId: 'CF14-TEST-SCENARIO',
    evidenceClass,
    status: 'PASS',
    exactHead: HEAD,
    source: `artifact://${evidenceClass}/evidence.json`,
    capturedAt: '2026-09-09T14:55:00+09:00',
    details: structuredClone(detailByClass[evidenceClass]),
    ...overrides,
  };
}

test('every evidence class requires substantive class-specific proof beyond a source string', () => {
  for (const evidenceClass of EVIDENCE_CLASSES) {
    assert.equal(validatePassEvidenceRecord(record(evidenceClass), { exactHead: HEAD }).evidenceClass, evidenceClass);
  }
});

test('browser PASS cannot be manufactured from a source reference without an interaction artifact and visible assertions', () => {
  assert.throws(
    () => validatePassEvidenceRecord(record('browser', { details: { entryBoundary: 'PWA route' } }), { exactHead: HEAD }),
    /interactionArtifact/,
  );
});

test('LINE PASS requires the provider event plus the actual reply artifact and family-visible result', () => {
  const details = structuredClone(detailByClass['line-transport']);
  delete details.replyArtifact;
  assert.throws(
    () => validatePassEvidenceRecord(record('line-transport', { details }), { exactHead: HEAD }),
    /replyArtifact/,
  );
});

test('physical iPhone PASS requires device context, real interaction steps and screenshots', () => {
  const details = structuredClone(detailByClass['physical-iphone-manual']);
  details.screenshotArtifacts = [];
  assert.throws(
    () => validatePassEvidenceRecord(record('physical-iphone-manual', { details }), { exactHead: HEAD }),
    /screenshotArtifacts requires at least 1 item/,
  );
});

test('Nursery image/OCR/AI PASS cannot start after OCR or skip review-stage provenance', () => {
  const details = structuredClone(detailByClass['image-ocr-ai']);
  details.stages = ['ai', 'review'];
  assert.throws(
    () => validatePassEvidenceRecord(record('image-ocr-ai', { details }), { exactHead: HEAD }),
    /must include classify in order/,
  );
});

test('cross-channel PASS requires both transport artifacts and a canonical readback', () => {
  const details = structuredClone(detailByClass['cross-channel-concurrency']);
  delete details.pwaArtifact;
  assert.throws(
    () => validatePassEvidenceRecord(record('cross-channel-concurrency', { details }), { exactHead: HEAD }),
    /pwaArtifact/,
  );
});

test('whole-day PASS requires morning-to-evening evidence in chronological order', () => {
  const details = structuredClone(detailByClass['whole-day-scenario']);
  details.timeline = [details.timeline[1], details.timeline[0], details.timeline[2]];
  assert.throws(
    () => validatePassEvidenceRecord(record('whole-day-scenario', { details }), { exactHead: HEAD }),
    /must be later than the previous step/,
  );
});

test('F2 record validation rejects a technically valid evidence class attached to the wrong scenario', () => {
  const bad = record('browser', { scenarioId: 'CF14-Q27-LINE-WEBHOOK-POSTBACK' });
  assert.throws(
    () => validateEvidenceRecords(cf14Scenarios, [bad], { exactHead: HEAD }),
    /browser is not a required evidence class/,
  );
});
