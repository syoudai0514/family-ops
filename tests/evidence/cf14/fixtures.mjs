export const rawLanguageCorpus = [
  {
    id: 'q70-three-intents',
    requirementIds: ['Q70'],
    rawText: '明日10時に予防接種。牛乳買って、ママにお迎えお願いして',
    expectedIntentKinds: ['event', 'shopping', 'request'],
    expectedMissingOnly: [],
  },
  {
    id: 'q70-event-share-task',
    requirementIds: ['Q70'],
    rawText: '金曜18時に保育園の面談。上履きも持っていく。ママにも共有して',
    expectedIntentKinds: ['event', 'task', 'share'],
    expectedMissingOnly: [],
  },
  {
    id: 'q71-only-time-ambiguous',
    requirementIds: ['Q71'],
    rawText: '明日の保育園面談を予定に入れて。時間はまだわからない',
    expectedIntentKinds: ['event'],
    expectedMissingOnly: ['time'],
  },
  {
    id: 'q71-only-request-target-ambiguous',
    requirementIds: ['Q71'],
    rawText: '明日のゴミ出しお願い。誰に頼むかはまだ決めてない',
    expectedIntentKinds: ['request'],
    expectedMissingOnly: ['recipient'],
  },
];

export const requestLifecycleFixtures = [
  {
    id: 'accepted-from-pending',
    initial: { attemptId: 'attempt-1', state: 'pending', revision: 1 },
    command: { kind: 'accept', expectedRevision: 1 },
    expected: { state: 'accepted', revision: 2, terminal: true },
  },
  {
    id: 'expired-does-not-revive',
    initial: { attemptId: 'attempt-2', state: 'expired', revision: 4 },
    command: { kind: 'accept', expectedRevision: 4 },
    expected: { errorCode: 'ATTEMPT_EXPIRED', terminal: true },
  },
  {
    id: 'stale-revision-fails-closed',
    initial: { attemptId: 'attempt-3', state: 'checking', revision: 5 },
    command: { kind: 'confirm', expectedRevision: 4 },
    expected: { errorCode: 'STALE_REVISION', terminal: false },
  },
];

export const clockBoundaryFixtures = [
  {
    id: 'weekday-morning-before',
    requirementIds: ['Q88'],
    dayType: 'weekday',
    deliveryKind: 'morning',
    at: '2026-09-14T06:29:59+09:00',
    expectedShouldDeliver: false,
  },
  {
    id: 'weekday-morning-at-boundary',
    requirementIds: ['Q88'],
    dayType: 'weekday',
    deliveryKind: 'morning',
    at: '2026-09-14T06:30:00+09:00',
    expectedShouldDeliver: true,
  },
  {
    id: 'weekend-morning-before',
    requirementIds: ['Q88'],
    dayType: 'weekend',
    deliveryKind: 'morning',
    at: '2026-09-19T08:59:59+09:00',
    expectedShouldDeliver: false,
  },
  {
    id: 'weekend-morning-at-boundary',
    requirementIds: ['Q88'],
    dayType: 'weekend',
    deliveryKind: 'morning',
    at: '2026-09-19T09:00:00+09:00',
    expectedShouldDeliver: true,
  },
  {
    id: 'holiday-morning-before',
    requirementIds: ['Q88'],
    dayType: 'holiday',
    deliveryKind: 'morning',
    at: '2026-09-23T08:59:59+09:00',
    expectedShouldDeliver: false,
  },
  {
    id: 'holiday-morning-at-boundary',
    requirementIds: ['Q88'],
    dayType: 'holiday',
    deliveryKind: 'morning',
    at: '2026-09-23T09:00:00+09:00',
    expectedShouldDeliver: true,
  },
  {
    id: 'evening-before',
    requirementIds: ['Q88'],
    dayType: 'weekday',
    deliveryKind: 'evening',
    at: '2026-09-14T20:29:59+09:00',
    expectedShouldDeliver: false,
  },
  {
    id: 'evening-at-boundary',
    requirementIds: ['Q88'],
    dayType: 'weekday',
    deliveryKind: 'evening',
    at: '2026-09-14T20:30:00+09:00',
    expectedShouldDeliver: true,
  },
];

// 1x1 transparent PNG. It is intentionally bytes, not OCR/candidate JSON.
export const nurseryActualImageFixture = {
  id: 'nursery-image-actual-input-1',
  requirementIds: Array.from({ length: 18 }, (_, index) => `Q${89 + index}`),
  mimeType: 'image/png',
  imageBase64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  fileName: 'nursery-notice-fixture.png',
};

export const wholeDaySkeleton = [
  { id: 'morning-brief', channel: 'line', at: '2026-09-14T06:30:00+09:00' },
  { id: 'morning-today', channel: 'pwa', at: '2026-09-14T06:35:00+09:00' },
  { id: 'daytime-change', channel: 'line', at: '2026-09-14T12:10:00+09:00' },
  { id: 'pwa-cross-check', channel: 'pwa', at: '2026-09-14T12:11:00+09:00' },
  { id: 'evening-brief', channel: 'line', at: '2026-09-14T20:30:00+09:00' },
  { id: 'evening-reconcile', channel: 'pwa', at: '2026-09-14T20:35:00+09:00' },
];
