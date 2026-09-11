import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';

export function buildLineWebhookEnvelope({ channelSecret, event, destination = 'Ucf14testdestination' }) {
  assert.equal(typeof channelSecret, 'string', 'LINE channel secret required');
  assert.ok(channelSecret.length > 0, 'LINE channel secret must not be blank');
  assert.equal(typeof event, 'object', 'LINE webhook event required');
  assert.ok(['message', 'postback'].includes(event?.type), 'LINE event must be message or postback');
  if (event.type === 'message') {
    assert.equal(event.message?.type, 'text', 'LINE message harness requires a text message event');
    assert.equal(typeof event.message?.text, 'string', 'LINE text payload required');
  }
  if (event.type === 'postback') {
    assert.equal(typeof event.postback?.data, 'string', 'LINE postback data required');
  }

  const body = JSON.stringify({ destination, events: [event] });
  const signature = createHmac('sha256', channelSecret).update(body, 'utf8').digest('base64');
  return {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-line-signature': signature,
    },
    body,
  };
}

export async function runSignedLineWebhookHttpScenario(adapter, input) {
  assert.equal(typeof adapter?.postWebhook, 'function', 'LINE HTTP adapter.postWebhook required');
  const envelope = buildLineWebhookEnvelope(input);
  const result = await adapter.postWebhook(envelope);
  assert.equal(result.entryBoundary, 'line-messaging-api', 'signed LINE envelope must terminate at LINE Messaging API webhook boundary');
  assert.equal(result.signatureVerified, true, 'LINE signature must be verified at the HTTP boundary');
  assert.ok(Number.isInteger(result.httpStatus) && result.httpStatus >= 200 && result.httpStatus < 300, 'LINE webhook must return 2xx');
  assert.ok(result.providerEventId, 'LINE webhook event id required');
  assert.ok(result.canonicalReadback, 'LINE webhook canonical readback required');
  assert.equal(typeof result.userVisibleResult, 'string', 'LINE transport evidence must include the user-visible reply/result');
  assert.ok(result.userVisibleResult.trim().length > 0, 'LINE transport evidence must not hide the user-visible reply/result');
  return { envelope, result };
}
