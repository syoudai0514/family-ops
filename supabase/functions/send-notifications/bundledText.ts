import { itemBlockText } from './blockText.ts';
import { buildCheckinLink, buildTodayLinkFooter } from '../_shared/lineMessaging.ts';
import { requestOutcomeText } from './requestNotificationPayload.ts';

type OutboxTextItem = Parameters<typeof requestOutcomeText>[0] & { session_id?: string };

/** Preserve the full bundle; the shared LINE builder applies the API budget. */
export function buildBundledText(
  payload: { items?: OutboxTextItem[] } | null,
  type: string,
  recipientUserId?: string | null,
  lead?: string | null,
): { text: string; sessionIds: string[] } {
  const items = payload?.items ?? [];
  const seenSessionIds = new Set<string>();
  const blocks = items.length > 0 ? items.map((item) => {
    let block = requestOutcomeText(item) ?? itemBlockText(item.title ?? '', item.body ?? '');
    if (type === 'routine' && item.session_id && !seenSessionIds.has(item.session_id)) {
      seenSessionIds.add(item.session_id);
      block += `\n${buildCheckinLink(item.session_id)}`;
    }
    return block;
  }) : [`Family Ops: ${type}`];
  const footer = buildTodayLinkFooter(type, recipientUserId);
  return {
    text: [lead, ...blocks, footer].filter((block) => block && block.length > 0).join('\n\n'),
    sessionIds: Array.from(seenSessionIds),
  };
}
