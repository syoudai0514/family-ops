import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';
import { runSignedLineWebhookHttpScenario } from './line-http-harness.mjs';

const CHANNEL_SECRET = 'cf14-line-test-secret';

function providerAdapter(expectedType) {
  return {
    async postWebhook(envelope) {
      assert.equal(envelope.method, 'POST');
      assert.equal(envelope.headers['content-type'], 'application/json');
      const expectedSignature = createHmac('sha256', CHANNEL_SECRET)
        .update(envelope.body, 'utf8')
        .digest('base64');
      assert.equal(envelope.headers['x-line-signature'], expectedSignature);
      const payload = JSON.parse(envelope.body);
      assert.equal(payload.events.length, 1);
      assert.equal(payload.events[0].type, expectedType);
      return {
        entryBoundary: 'line-messaging-api',
        signatureVerified: true,
        httpStatus: 200,
        providerEventId: payload.events[0].webhookEventId,
        canonicalReadback: { state: expectedType === 'message' ? 'pending' : 'accepted' },
        userVisibleResult: expectedType === 'message'
          ? '内容を確認してください'
          : 'お願いを「やる」で受け付けました',
      };
    },
  };
}

test('Q27/Q70/Q71 LINE text evidence starts from a signed Messaging API HTTP envelope and retains a user-visible result', async () => {
  const event = {
    type: 'message',
    mode: 'active',
    timestamp: 1788930000000,
    webhookEventId: 'line-message-event-1',
    replyToken: 'reply-token-1',
    source: { type: 'user', userId: 'Ucf14testuser' },
    message: {
      id: 'message-1',
      type: 'text',
      text: '明日10時に予防接種。牛乳買って、ママにお迎えお願いして',
    },
  };
  const { envelope, result } = await runSignedLineWebhookHttpScenario(providerAdapter('message'), {
    channelSecret: CHANNEL_SECRET,
    event,
  });
  assert.match(envelope.headers['x-line-signature'], /^[A-Za-z0-9+/]+=*$/);
  assert.equal(result.providerEventId, 'line-message-event-1');
  assert.equal(result.userVisibleResult, '内容を確認してください');
});

test('Q27 LINE postback evidence starts from a signed Messaging API HTTP envelope and returns user-visible confirmation', async () => {
  const event = {
    type: 'postback',
    mode: 'active',
    timestamp: 1788930001000,
    webhookEventId: 'line-postback-event-1',
    replyToken: 'reply-token-2',
    source: { type: 'user', userId: 'Ucf14testuser' },
    postback: { data: 'action=request_accept&request_id=req-1&expected_revision=3' },
  };
  const { result } = await runSignedLineWebhookHttpScenario(providerAdapter('postback'), {
    channelSecret: CHANNEL_SECRET,
    event,
  });
  assert.equal(result.providerEventId, 'line-postback-event-1');
  assert.equal(result.canonicalReadback.state, 'accepted');
  assert.match(result.userVisibleResult, /やる/);
});

test('LINE HTTP harness refuses malformed postback fixtures before an adapter can claim transport evidence', async () => {
  await assert.rejects(
    () => runSignedLineWebhookHttpScenario(providerAdapter('postback'), {
      channelSecret: CHANNEL_SECRET,
      event: { type: 'postback', postback: {} },
    }),
    /LINE postback data required/,
  );
});

test('LINE HTTP harness rejects technically successful transport evidence when no user-visible result exists', async () => {
  await assert.rejects(
    () => runSignedLineWebhookHttpScenario({
      async postWebhook(envelope) {
        const payload = JSON.parse(envelope.body);
        return {
          entryBoundary: 'line-messaging-api',
          signatureVerified: true,
          httpStatus: 200,
          providerEventId: payload.events[0].webhookEventId,
          canonicalReadback: { state: 'pending' },
          userVisibleResult: '',
        };
      },
    }, {
      channelSecret: CHANNEL_SECRET,
      event: {
        type: 'message',
        webhookEventId: 'line-no-visible-result',
        message: { type: 'text', text: '今日' },
      },
    }),
    /must not hide the user-visible reply\/result/,
  );
});
