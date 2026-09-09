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

// Synthetic, high-contrast Japanese nursery notice. F2 decodes these bytes and
// must start at the image/provider boundary rather than post-OCR candidate JSON.
export const nurseryActualImageFixture = {
  id: 'nursery-image-actual-input-1',
  requirementIds: Array.from({ length: 18 }, (_, index) => `Q${89 + index}`),
  mimeType: 'image/png',
  imageBase64: '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',
  fileName: 'nursery-notice-synthetic-ja.png',
  expectedSourceHints: ['サンプル保育園', 'そらぐみ', '9月15日', '秋の遠足', '水筒', '参加確認票'],
};

export const wholeDaySkeleton = [
  { id: 'morning-brief', channel: 'line', at: '2026-09-14T06:30:00+09:00' },
  { id: 'morning-today', channel: 'pwa', at: '2026-09-14T06:35:00+09:00' },
  { id: 'daytime-change', channel: 'line', at: '2026-09-14T12:10:00+09:00' },
  { id: 'pwa-cross-check', channel: 'pwa', at: '2026-09-14T12:11:00+09:00' },
  { id: 'evening-brief', channel: 'line', at: '2026-09-14T20:30:00+09:00' },
  { id: 'evening-reconcile', channel: 'pwa', at: '2026-09-14T20:35:00+09:00' },
];
