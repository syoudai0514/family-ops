import { describe, expect, it } from 'vitest';
import { requestNotificationHref } from './Notifications';

describe('request links in notification history', () => {
  const requestId = '1fa845ae-be2d-4947-b709-396478a40272';

  it.each(['request.received', 'request_received', 'request.consulting', 'request.awaiting_confirmation', 'request.accepted', 'request.followup_requested'])('links %s to the correct request', (type) => {
    expect(requestNotificationHref({ type, payload: { request_id: requestId } })).toBe(`/requests?request=${requestId}`);
  });

  it('requires a known request notification and a valid request id', () => {
    expect(requestNotificationHref({ type: 'request.consulting', payload: null })).toBeNull();
    expect(requestNotificationHref({ type: 'request.received', payload: { request_id: '../tasks' } })).toBeNull();
    expect(requestNotificationHref({ type: 'handover.created', payload: { request_id: requestId } })).toBeNull();
  });
});
