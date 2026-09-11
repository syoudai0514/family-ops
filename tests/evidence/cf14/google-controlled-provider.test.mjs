import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createControlledGoogleProvider,
  runControlledGoogleProviderScenario,
} from './google-controlled-provider-harness.mjs';

const EXTERNAL_EVENT_ID = 'google-event-cf14-1';
const routes = [
  {
    operation: 'updated',
    externalEventId: EXTERNAL_EVENT_ID,
    etag: 'etag-update-2',
    payload: { status: 'confirmed', startsAt: '2026-09-20T11:00:00+09:00' },
  },
  {
    operation: 'deleted',
    externalEventId: EXTERNAL_EVENT_ID,
    etag: 'etag-delete-3',
    payload: { status: 'cancelled' },
  },
  {
    operation: 'duplicate-search',
    externalEventId: EXTERNAL_EVENT_ID,
    etag: 'etag-duplicate-4',
    payload: { matches: [{ externalEventId: EXTERNAL_EVENT_ID, title: '保育園面談' }] },
  },
];

function consumerFor(kind) {
  return {
    async applyProviderResponse({ providerResponse }) {
      if (kind === 'updated') {
        return {
          canonicalReadback: { startsAt: '2026-09-20T10:00:00+09:00', protected: true },
          userVisibleResult: 'Google側の日時変更を確認してください',
          currentValuePreserved: true,
          candidate: { startsAt: providerResponse.payload.startsAt },
        };
      }
      if (kind === 'deleted') {
        return {
          canonicalReadback: { status: 'scheduled' },
          userVisibleResult: 'Google側で予定が削除されています',
          choices: ['予定を中止', '別日に変更予定', 'Googleだけから消した'],
        };
      }
      return {
        canonicalReadback: { linkedExternalEventId: null },
        userVisibleResult: '同じ予定らしいGoogle予定があります',
        choices: ['既存Google予定へ紐づける', '別件として追加'],
      };
    },
  };
}

test('Q110 controlled provider keeps a protected current date and exposes the Google date as a candidate', async () => {
  const provider = createControlledGoogleProvider(routes);
  const fixture = {
    id: 'q110-google-date-change',
    operation: 'updated',
    externalEventId: EXTERNAL_EVENT_ID,
    expectedCurrentValuePreserved: true,
    expectedCandidateStartsAt: '2026-09-20T11:00:00+09:00',
  };
  const { result } = await runControlledGoogleProviderScenario({ provider, consumer: consumerFor('updated'), fixture });
  assert.equal(result.canonicalReadback.startsAt, '2026-09-20T10:00:00+09:00');
  assert.deepEqual(provider.calls, [{ operation: 'updated', externalEventId: EXTERNAL_EVENT_ID }]);
});

test('Q111 controlled provider deletion requires the three canonical user choices', async () => {
  const provider = createControlledGoogleProvider(routes);
  const fixture = {
    id: 'q111-google-deletion',
    operation: 'deleted',
    externalEventId: EXTERNAL_EVENT_ID,
    expectedChoices: ['予定を中止', '別日に変更予定', 'Googleだけから消した'],
  };
  const { result } = await runControlledGoogleProviderScenario({ provider, consumer: consumerFor('deleted'), fixture });
  assert.equal(result.canonicalReadback.status, 'scheduled');
});

test('Q112 controlled provider duplicate requires link-existing versus add-separate resolution', async () => {
  const provider = createControlledGoogleProvider(routes);
  const fixture = {
    id: 'q112-google-duplicate',
    operation: 'duplicate-search',
    externalEventId: EXTERNAL_EVENT_ID,
    expectedChoices: ['既存Google予定へ紐づける', '別件として追加'],
  };
  const { result } = await runControlledGoogleProviderScenario({ provider, consumer: consumerFor('duplicate'), fixture });
  assert.equal(result.canonicalReadback.linkedExternalEventId, null);
});

test('controlled Google provider cannot be replaced by a DB/RPC-only response', async () => {
  const provider = {
    async request() {
      return {
        entryBoundary: 'db-rpc',
        provider: 'google-calendar',
        httpStatus: 200,
        externalEventId: EXTERNAL_EVENT_ID,
        etag: 'fake',
        payload: {},
      };
    },
  };
  await assert.rejects(
    () => runControlledGoogleProviderScenario({
      provider,
      consumer: consumerFor('updated'),
      fixture: {
        id: 'reject-db-only',
        operation: 'updated',
        externalEventId: EXTERNAL_EVENT_ID,
      },
    }),
    /google-calendar-provider/,
  );
});
